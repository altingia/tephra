package Tephra::Genome::MaskRef;

use 5.014;
use Moose;
use File::Spec;
use File::Find;
use File::Basename;
use Cwd         qw(abs_path);
use File::Path  qw(make_path remove_tree);
use List::Util  qw(sum);
use Log::Any    qw($log);
use Time::HiRes qw(gettimeofday);
use Sort::Naturally;
use Set::IntervalTree;
use Parallel::ForkManager;
use namespace::autoclean;
#use Data::Dump::Color qw(dump dd);

with 'Tephra::Role::Util',
     'Tephra::Role::Run::GT';

=head1 NAME

Tephra::Genome::MaskRef - Mask a reference with repeats to reduce false positives

=head1 VERSION

Version 0.06.0

=cut

our $VERSION = '0.06.0';
$VERSION = eval $VERSION;

has genome => (
      is       => 'ro',
      isa      => 'Maybe[Str]',
      required => 1,
      coerce   => 0,
);

has repeatdb => (
      is       => 'ro',
      isa      => 'Maybe[Str]',
      required => 0,
      coerce   => 0,
);

has outfile => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    required => 1,
    coerce   => 0,
);

has clean => (
    is       => 'ro',
    isa      => 'Bool',
    required => 0,
    default  => 1,
);

has threads => (
    is        => 'ro',
    isa       => 'Int',
    predicate => 'has_threads',
    lazy      => 1,
    default   => 1,
);

has hit_pid => (
    is      => 'ro',
    isa     => 'Int',
    default => 80,
);

has splitsize => (
    is        => 'ro',
    isa       => 'Num',
    predicate => 'has_splitsize',
    lazy      => 1,
    default   => 5e4,
);

has overlap => (
    is        => 'ro',
    isa       => 'Int',
    predicate => 'has_overlap',
    lazy      => 1,
    default   => 100,
);

has hitlength => (
    is      => 'ro',
    isa     => 'Int',
    default => 70,
);

sub mask_reference {
    my $self = shift;
    my $genome  = $self->genome;
    my $threads = $self->threads;

    my $t0 = gettimeofday();
    my ($name, $path, $suffix) = fileparse($genome, qr/\.[^.]*/);
    if ($name =~ /(\.fa.*)/) {
	$name =~ s/$1//;
    }

    my $outfile  = $self->outfile // File::Spec->catfile( abs_path($path), $name.'_masked.fas' );
    if (-e $outfile) {
	say STDERR "\nERROR: '$outfile' already exists. Please delete this or rename it before proceeding. Exiting.\n";
        exit(1);
    }
    my $logfile = $outfile.'.log';

    open my $out, '>>', $outfile or die "\nERROR: Could not open file: $outfile\n";
    open my $log, '>>', $logfile or die "\nERROR: Could not open file: $logfile\n";

    my $genome_dir = File::Spec->catfile( abs_path($path), $name.'_tephra_masked_tmp' );

    if (-d $genome_dir) {
	say STDERR "\nERROR: '$genome_dir' already exists. Please delete this or rename it before proceeding. Exiting.\n";
	exit(1);
    }
    else {
	make_path( $genome_dir, {verbose => 0, mode => 0771,} );
    }

    my $files = $self->_split_genome($genome, $genome_dir);
    die "\nERROR: No FASTA files found in genome directory. Exiting.\n" if @$files == 0;

    my $thr;
    if ($threads % 2 == 0) {
	$thr = sprintf("%.0f",$threads/2);
    }
    elsif ($threads-1 % 2 == 0) {
	$thr = sprintf("%.0f",$threads-1/2);
    }
    else {
	$thr = 1;
    }

    my $pm = Parallel::ForkManager->new($thr);
    local @{$SIG}{qw(INT TERM)} = sub {
        $log->warn("Caught SIGINT or SIGTERM; Waiting for child processes to finish.");
        $pm->wait_all_children;
        exit 1;
    };

    my (@reports, %seqs);
    $pm->run_on_finish( sub { my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_ref) = @_;
			      my ($report, $ref, $id, $seq, $path) 
				  = @{$data_ref}{qw(masked ref id seq path)};
			      push @reports, $report;
			      $seqs{$ref}{$id} = $seq;
			      my $t1 = gettimeofday();
                              my $elapsed = $t1 - $t0;
                              my $time = sprintf("%.2f",$elapsed/60);
                              say $log basename($ident),
                              " just finished with PID $pid and exit code: $exit_code in $time minutes";
                        } );

    for my $chr (nsort @$files) {
	my $chr_windows = $self->_split_chr_windows($chr);
	my $window_ct = keys %$chr_windows;
	for my $seq_index (sort { $a <=> $b } keys %$chr_windows) {
	    my $wchr = $chr_windows->{$seq_index};
	    $pm->start($wchr) and next;
	    @{$SIG}{qw(INT TERM)} = sub { $pm->finish };
	    my $mask_struct = $self->run_masking($seq_index, $chr_windows, $chr, $wchr);
	    
	    $pm->finish(0, $mask_struct);
	}
	unlink $chr;
    }

    $pm->wait_all_children;

    $self->write_masking_results(\@reports, \%seqs, $out, $outfile, $t0);
    remove_tree( $genome_dir, { safe => 1 } ) if $self->clean;
    close $log;

    return;
}

sub run_masking {
    my $self = shift;
    my ($seq_index, $chr_windows, $chr, $wchr) = @_;
    my $repeatdb = $self->repeatdb;
    my $length   = $self->hitlength;
    my $pid      = $self->hit_pid;

    my ($cname, $cpath, $csuffix) = fileparse($wchr, qr/\.[^.]*/);
    if ($cname =~ /(\.fa.*)/) {
	$cname =~ s/$1//;
    }

    my $sub_chr_length = $self->get_mask_stats($wchr);

    my $report  = File::Spec->catfile( abs_path($cpath), $cname.'_vmatch_report.txt' );
    my $outpart = File::Spec->catfile( abs_path($cpath), $cname.'_masked.fas' );

    my $index = File::Spec->catfile( abs_path($cpath), $cname.'.index' );
    my $mkvtree_log = File::Spec->catfile( abs_path($cpath), $cname.'_mkvtree_log.err' );
    my $vmatch_mlog = File::Spec->catfile( abs_path($cpath), $cname.'_vmatch_mask.err' );
    my $vmatch_rlog = File::Spec->catfile( abs_path($cpath), $cname.'_vmatch_aln.err' );

    my $thr = 2;
    my $pm = Parallel::ForkManager->new($thr);
    local $SIG{INT} = sub {
        $log->warn("Caught SIGINT; Waiting for child processes to finish.");
        $pm->wait_all_children;
         exit 1;
    };

    my $mkvtree = "mkvtree -db $wchr -indexname $index -dna -allout -v -pl 2>&1 > $mkvtree_log";
    my $vmatchm = "vmatch -p -d -q $repeatdb -qspeedup 2 -l $length -best 10000 -identity $pid -dbmaskmatch N $index 1> $outpart 2> $vmatch_mlog";
    my $vmatchr = "vmatch -p -d -q $repeatdb -qspeedup 2 -l $length -best 10000 -sort ia -identity $pid -showdesc 0 $index 1> $report 2> $vmatch_rlog";

    $self->run_cmd($mkvtree); # need to warn here, not just log errors
    for my $run ($vmatchm, $vmatchr) {
	$pm->start($run) and next;
	$SIG{INT} = sub { $pm->finish };
	$self->run_cmd($run);
	$pm->finish;
    }

    $pm->wait_all_children;

    my $mask_struct = $self->get_masking_results($wchr, $report, $sub_chr_length, $seq_index, $chr_windows);

    $self->clean_index_files($index);
    my ($id, $seq) = $self->_get_seq($outpart);
    # each reference sequence is in a separate directory so we just need that directory name 
    my $ref = dirname($chr);
    $ref =~ s/.*\///;

    unlink $mkvtree_log, $vmatch_mlog, $vmatch_rlog, $outpart if $self->clean;

    return { masked => $mask_struct, 
	     ref    => $ref, 
	     id     => $id, 
	     seq    => $seq, 
	     path   => $cpath };
}

sub get_masking_results {
    my $self = shift;
    my ($chr, $voutfile, $sub_chr_length, $seq_index, $chr_windows) = @_;
    my $genome  = $self->genome;
    my $outfile = $self->outfile;
    my $overlap_size = $self->overlap;

    # Because of the overlapping segments, we need to get the coordinates correct
    # in order to just measure repeats in the masking window, not in the overlapping regions
    # (which would artifically increase the repetitiveness of the genome). That is what
    # the variables below are doing.
    my ($rep_start, $rep_end);
    if ($chr_windows > 1) {
	$rep_start = $seq_index > 0 ? $overlap_size : 1;
	$rep_end = $sub_chr_length-$overlap_size;
    }
    else {
	$rep_start = 1;
	$rep_end = $sub_chr_length;
    }

    my $repeat_map = $self->_build_repeat_map;

    open my $in, '<', $voutfile or die "\nERROR: Could not open file: $voutfile\n";
    
    my (%windows, %refs, %hits, %aligns, %report, %final_rep);

    # The alignments are sorted by coordinates, so to find overlapping alignments within
    # an interval you need to first grab the first alignment, and then use subsequent
    # alignments for comparison with an Interval Tree. That is what the closure below is doing. 
    # Also, we have to adjust for the overlaps and window size, as described above.
    my $tree = Set::IntervalTree->new;
    my $comm = <$in>; # discard the args to vmatch
    my $firstline;
    line : { 
	$firstline = <$in>;
	unless (defined $firstline && $firstline =~ /\S/) {
	    # if no hits, return
	    close $in;
	    unlink $voutfile;
	    return \%report;
	}
	# $line is the following format: 
	# l(S) h(S) r(S) t l(Q) h(Q) r(Q) d e s i
	# where:
	# l = length
	# h = sequence header
	# r = relative position
	# t = type (D=direct, P=palindromic)
	# d = distance value (negative=hamming distance, 0=exact, positive=edit distance)
	# e = E-value
	# s = score value (negative=hamming score, positive=edit score)
	# i = percent identity
	# (S) = in Subject
	# (Q) = in Query
	$firstline = <$in>;
	chomp $firstline;
	$firstline =~ s/^\s+//;
	my @f = split /\s+/, $firstline;
	my $send = $f[2] + $f[0];
	# The next line checks if we are within the masking window or in an overlapping region. 
	# If not in the masking window, grab the next alignment and evaluate.
	redo line unless $f[2] >= $rep_start;

	$tree->insert({ id => $f[1], match => $f[5], start => $f[2], end => $send, len => $f[0] }, 
		      $f[2], $send);
	$windows{$f[2]} = { start => $f[2], end => $send, len => $f[0], overlap => 0, match => $f[5] };
    }

    while (my $line = <$in>) {
	chomp $line;
	$line =~ s/^\s+//;
	my ($slen, $sid, $spos, $htype, $qlen, $hid, $qpos, $dist, $evalue, $score, $pid) = split /\s+/, $line;
	my $end = $spos + $slen;
	# The next two lines check if we are within the masking window or in an overlapping region.
	next unless $spos >= $rep_start;
	last if $end >= $rep_end;
	my $res = $tree->fetch($spos, $end);
    
	if (@$res) {
	    my ($best_start, $best_end, $overl, $best_match);
	    for my $overlap (@$res) {           
		my ($ostart, $oend, $match, $subj, $olen) = @{$overlap}{qw(start end match id len)};

		$best_start = $ostart <= $spos ? $ostart : $spos;
		$best_end = $oend >= $end ? $oend : $end;
		my $oe = $best_end == $oend ? $end : $oend;
		$overl = $best_end - $oe;

		$tree->remove($ostart, $oend);
	    }
        
	    my $nlen = $best_start > 0 ? $best_end-$best_start : $best_end;
	    $windows{$best_start} = { start => $best_start, end => $best_end, len => $nlen, match => $hid, overlap => $overl };
	    $tree->insert({ id => $sid, match => $hid, start => $best_start, end => $best_end, len => $nlen }, 
			  $best_start, $best_end);
	}
	else {
	    $tree->insert({ id => $sid, match => $hid, start => $spos, end => $end, len => $slen }, 
			  $spos, $end);
	    $windows{$spos} = { start => $spos, end => $end, len => $slen, overlap => 0, match => $hid};
	}
    }
    close $in;
    
    for my $s (sort { $a <=> $b } keys %windows) {
	if (exists $windows{ $windows{$s}{end} }) {
	    my $h = $windows{ $windows{$s}{end} };
	    $windows{ $windows{$s}{end} } = { start   => $h->{start}+1, 
					      end     => $h->{end},
					      match   => $h->{match},
					      len     => $h->{len}-1,
					      overlap => 0 };
	}
    }

    for my $s (sort { $a <=> $b } keys %windows) { 
	my ($code) = ($windows{$s}{match} =~ /^(\w{3})-?_?/);         
	if (defined $code && exists $repeat_map->{$code}) {
	    push @{$report{ $code }}, $windows{$s}{len};
	}
    }

    unlink $voutfile if $self->clean;
    return \%report;
}

sub write_masking_results {
    my $self = shift;
    my ($reports, $seqs, $out, $outfile, $t0) = @_;
    my $genome = $self->genome;
    my $split_size = $self->splitsize;
    my $overlap = $self->overlap;

    # first write out the masked reference
    my ($seqct, $genome_length) = (0, 0);

    # The for-loop below is adjusting the subsets to remove the overlaps 
    # so the the final masked reference accurately reflects the input reference
    # chromosomes. The only difference will be that the output chromosomes
    # are sorted by the ID (the only other option would be a random order, which
    # is not useful at all for comparison purposes or debugging).
    # NB: This is a new method in v0.04.4, so I'm leaving the debugging statements
    # in place for now.
    for my $id (nsort keys %$seqs) {
	my $seq;
	my @subsets = nsort keys %{$seqs->{$id}};
	my $final = $subsets[-1];
	#say STDERR "final: $final";
	if (@subsets > 1) {
	    for my $subs (@subsets) {
		my $length = length($seqs->{$id}{$subs});
		#say STDERR join q{ }, $id, $subs, $length;
		if ($seqct > 0) {
		    if ($subs eq $final) {
			$length -= $overlap;
			#say STDERR join q{ }, 'final: ', $subs, $overlap, $length;
			my $seqpart = substr $seqs->{$id}{$subs}, $overlap, $length;
			$seq .= $seqpart;
			#say STDERR join q{ }, 'final: ', $id, $subs, length($seqpart);
			$genome_length += length($seqpart);
		    }
		    else {
			$length -= $overlap*2;
			my $seqpart = substr $seqs->{$id}{$subs}, $overlap, $length;
			$seq .= $seqpart;
			$genome_length += length($seqpart);
			#say STDERR join q{ }, $id, $subs, length($seqpart);
		    }
		}
		else {
		    $length -= $overlap;
		    my $seqpart = substr $seqs->{$id}{$subs}, 0, $length;
		    $seq .= $seqpart;
		    $genome_length += length($seqpart);
		    #say STDERR join q{ }, $id, $subs, length($seqpart);
		}
		$seqct++;
	    }
	}
	else {
	    my ($subsetid) = keys %{$seqs->{$id}};
	    $seq = $seqs->{$id}{$subsetid};
	    #say STDERR join q{ }, $id, $subsetid, length($seq);
	    $genome_length += length($seq);
	}
	$seq =~ s/.{60}\K/\n/g;
	#say STDERR join q{ }, $id, length($seq);
	say $out join "\n", ">$id", $seq;
	$seqct = 0;
    }

    my %final_rep;
    my $repeat_map = $self->_build_repeat_map;

    my ($classlen, $orderlen, $namelen, $masklen);
    for my $report (@$reports) {
	next unless %$report;
	for my $rep_type (keys %$report) {
            my $total = sum(@{$report->{$rep_type}});
            my ($class, $order, $name) = @{$repeat_map->{$rep_type}}{qw(class order repeat_name)};
            ($classlen, $orderlen, $namelen) = (length($class), length($order), length($name)); 
            $final_rep{$class}{$order}{$name} += $total;
        }
    }
    
    my $t2 = gettimeofday();
    my $total_elapsed = $t2 - $t0;
    my $final_time = sprintf("%.2f",$total_elapsed/60);

    ($classlen,$orderlen, $namelen) = ($classlen+10, $orderlen+10, $namelen+15);
    my $masked_total = 0;
    say "=================== 'Tephra maskref' finished in $final_time minutes ==================";
    printf "%-${classlen}s %-${classlen}s %-${orderlen}s %-${namelen}s\n", "Class", "Order", "Superfamily", "Percent Masked";

    say "-" x 80;
    for my $class (sort keys %final_rep) {
        for my $order (sort keys %{$final_rep{$class}}) {
            for my $name (sort keys %{$final_rep{$class}{$order}}) {
                $masked_total += $final_rep{$class}{$order}{$name};
                my $repmasked = sprintf("%.2f",($final_rep{$class}{$order}{$name}/$genome_length)*100);
                printf "%-${classlen}s %-${classlen}s %-${orderlen}s %-${namelen}s\n",
		    $class, $order, $name, "$repmasked% ($final_rep{$class}{$order}{$name}/$genome_length)";
            }
        }
    }

    my $masked = sprintf("%.2f",($masked_total/$genome_length)*100);
    say "=" x 80;
    say "Input file:          $genome";
    say "Output file:         $outfile";
    say "Masking window size: $split_size";
    say "Window overlap size: $overlap";
    say "Total genome length: $genome_length";
    say "Total masked bases:  $masked% ($masked_total/$genome_length)";

    return;
}

sub get_mask_stats {
    my $self = shift;
    my ($genome) = @_;

    my $kseq = Bio::DB::HTS::Kseq->new($genome);
    my $iter = $kseq->iterator;

    my $total;
    while (my $seqobj = $iter->next_seq) {
	my $name = $seqobj->name;
	my $seq  = $seqobj->seq;
	my $seqlength = length($seq);
	if ($seqlength > 0) {
	    $total += $seqlength;
	}
    }

    return $total;
}

sub _get_seq {
    my $self = shift;
    my ($fasta) = @_;

    my $kseq = Bio::DB::HTS::Kseq->new($fasta);
    my $iter = $kseq->iterator;

    my ($id, $seq);
    while (my $seqobj = $iter->next_seq) {
        $id = $seqobj->name;
	$seq = $seqobj->seq;
    }

    return ($id, $seq);
}

sub _split_genome {
    my $self = shift;
    my ($genome, $genome_dir) = @_;

    my @files;
    my $kseq = Bio::DB::HTS::Kseq->new($genome);
    my $iter = $kseq->iterator;
    while (my $seqobj = $iter->next_seq) {
	my $id = $seqobj->name;
	my $dir = File::Spec->catdir($genome_dir, $id);
	make_path( $dir, {verbose => 0, mode => 0771,} );
	my $outfile = File::Spec->catfile($dir, $id.'.fasta');
	open my $out, '>', $outfile or die "\nERROR: Could not open file: $outfile\n";
	say $out join "\n", ">".$id, $seqobj->seq;
	close $out;
	push @files, $outfile;
    }
    
    return \@files;
}

sub _split_chr_windows {
    my $self = shift;
    my ($genome) = @_;
    my $split_size = $self->splitsize;
    my $overlap = $self->overlap;

    my ($name, $path, $suffix) = fileparse($genome, qr/\.[^.]*/);

    my %split_files; 
    my $remainder = 0;
    my $kseq = Bio::DB::HTS::Kseq->new($genome);
    my $iter = $kseq->iterator;

    while (my $seqobj = $iter->next_seq) {
        my $id  = $seqobj->name;
        my $seq = $seqobj->seq;
        my $length = length($seq);
        $remainder = $length;
        my ($total, $start, $end, $chunk_size) = (0, 0, 0, 0);
        my $steps = sprintf("%.0f", $length/$split_size);
        # Since we start counting at 0, the next line ensures we don't make an extra (and empty) file 
        # when the desired split size is >= the sequence length.
        $steps = 0 if $length <= $split_size;

        for my $i (0..$steps) {
            last if $remainder == 0;
            if ($remainder < $chunk_size) {
                $start = $end - ($overlap*2);
                $end = $length;
		$chunk_size = $end - $start;
                my $seq_part = substr $seq, $start, $chunk_size;
                $seq_part =~ s/.{60}\K/\n/g;
                my $outfile = File::Spec->catfile($path, $id."_$i.fasta");
                open my $out, '>', $outfile or die "\nERROR: Could not open file: $outfile\n";
                say $out join "\n", ">".$id."_$i"."_".$start."_$end", $seq_part;
                close $out;
                $split_files{$i} = $outfile;
                last;
            }
            else {
                if ($i > 0) {
		    # If not the first window, then there are two overlaps (start and end).
		    $start = $end - ($overlap*2);
                    $end = $start + $split_size + ($overlap*2);
		    $chunk_size = $end - $start;
                }
                else {
		    # The next lines evaluate whether the remaining length is greater than the
		    # window size and overlap. If not, make the end the length to get the ID
		    # and chunk size correct.
                    $end = $length >= $split_size+$overlap ? $split_size+$overlap : $length;
		    $chunk_size = $length >= $split_size+$overlap ? $end - $start : $length;
                }

                my $seq_part = substr $seq, $start, $chunk_size;
                $seq_part =~ s/.{60}\K/\n/g;
                my $outfile = File::Spec->catfile($path, $id."_$i.fasta");
                open my $out, '>', $outfile or die "\nERROR: Could not open file: $outfile\n";
		# The next line is a small adjustment to show that the first window starts at 1 and not 0,
		# which is just to make it human-readable (even though to Perl, it really does start at 0).
                $start = $i > 0 ? $start : $start+1;
                say $out join "\n", ">".$id."_$i"."_".$start."_$end", $seq_part;
                close $out;
                $split_files{$i} = $outfile;
                $remainder -= $chunk_size;
                $i++;
            }
        }
    }

    return \%split_files; 
}

sub _build_repeat_map {
    my $self = shift;

    my %repeat_map = (
	## Class I
	# DIRS
	'RLD' => { class => 'Class I', order => 'DIRS', repeat_name => 'DIRS' },
	'RYN' => { class => 'Class I', order => 'DIRS', repeat_name => 'Ngaro' },
	'RYX' => { class => 'Class I', order => 'DIRS', repeat_name => 'Unknown DIRS' },
	'RYV' => { class => 'Class I', order => 'DIRS', repeat_name => 'VIPER' },
	# LINE 
	'RII' => { class => 'Class I', order => 'LINE', repeat_name => 'I' },
	'RIJ' => { class => 'Class I', order => 'LINE', repeat_name => 'Jockey' },
	'RIL' => { class => 'Class I', order => 'LINE', repeat_name => 'L1' },
	'RIR' => { class => 'Class I', order => 'LINE', repeat_name => 'R2' },
	'RIT' => { class => 'Class I', order => 'LINE', repeat_name => 'RTE' },
	'RIX' => { class => 'Class I', order => 'LINE', repeat_name => 'Unknown LINE' },
	'RIC' => { class => 'Class I', order => 'LINE', repeat_name => 'CR1' },
	# LTR
	'RLB' => { class => 'Class I', order => 'LTR', repeat_name => 'Bel/Pao' },
	'RLC' => { class => 'Class I', order => 'LTR', repeat_name => 'Copia' },
	'RLE' => { class => 'Class I', order => 'LTR', repeat_name => 'ERV' },
	'RLG' => { class => 'Class I', order => 'LTR', repeat_name => 'Gypsy' },
	'RLR' => { class => 'Class I', order => 'LTR', repeat_name => 'Retrovirus' },
	'RLT' => { class => 'Class I', order => 'LTR', repeat_name => 'TRIM' },
	'RLX' => { class => 'Class I', order => 'LTR', repeat_name => 'Unknown LTR' },
	# PLE
	'RPP' => { class => 'Class I', order => 'Penelope', repeat_name => 'Penelope' },
	'RPX' => { class => 'Class I', order => 'Penelope', repeat_name => 'Unknown PLE' },
	# SINE
	'RSS' => { class => 'Class I', order => 'SINE', repeat_name => '5S' },
	'RSL' => { class => 'Class I', order => 'SINE', repeat_name => '7SL' },
	'RST' => { class => 'Class I', order => 'SINE', repeat_name => 'tRNA' },
	'RSX' => { class => 'Class I', order => 'SINE', repeat_name => 'Unknown SINE' },
	'RXX' => { class => 'Class I', order => 'SINE', repeat_name => 'Unknown retrotransposon' },
	## Class II
	# - Subclass 1
	# Crypton
	'DYC' => { class => 'Class II', order => 'Crypton', repeat_name => 'Crypton' },
	'DYX' => { class => 'Class II', order => 'Crypton', repeat_name => 'Unknown Crypton' },
	# TIR
	'DTC' => { class => 'Class II', order => 'TIR', repeat_name => 'CACTA' },
	'DTA' => { class => 'Class II', order => 'TIR', repeat_name => 'hAT' },
	'DTE' => { class => 'Class II', order => 'TIR', repeat_name => 'Merlin' },
	'DTM' => { class => 'Class II', order => 'TIR', repeat_name => 'Mutator' },
	'DTP' => { class => 'Class II', order => 'TIR', repeat_name => 'P' },
	'DTH' => { class => 'Class II', order => 'TIR', repeat_name => 'PIF/Harbinger' },
	'DTB' => { class => 'Class II', order => 'TIR', repeat_name => 'PiggyBac' },
	'DTT' => { class => 'Class II', order => 'TIR', repeat_name => 'Tc1/Mariner' },
	'DTR' => { class => 'Class II', order => 'TIR', repeat_name => 'Transib' },
	'DTX' => { class => 'Class II', order => 'TIR', repeat_name => 'Unknown TIR' },
	'DXX' => { class => 'Class II', order => 'TIR', repeat_name => 'Unknown DNA transposon' },
	# - Subclass 2
	# Helitron
	'DHH' => { class => 'Class II', order => 'Helitron', repeat_name => 'Helitron' },
	'DHX' => { class => 'Class II', order => 'Helitron', repeat_name => 'Unknown Helitron' },
	# Maverick
	'DMM' => { class => 'Class II', order => 'Maverick', repeat_name => 'Maverick' },
	'DMX' => { class => 'Class II', order => 'Maverick', repeat_name => 'Unknown Maverick' },
	);

    return \%repeat_map;
}

=head1 AUTHOR

S. Evan Staton, C<< <statonse at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests through the project site at 
L<https://github.com/sestaton/tephra/issues>. I will be notified,
and there will be a record of the issue. Alternatively, I can also be 
reached at the email address listed above to resolve any questions.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Tephra::Genome::MaskRef


=head1 LICENSE AND COPYRIGHT

Copyright (C) 2015- S. Evan Staton

This program is distributed under the MIT (X11) License, which should be distributed with the package. 
If not, it can be found here: L<http://www.opensource.org/licenses/mit-license.php>

=cut

__PACKAGE__->meta->make_immutable;

1;
