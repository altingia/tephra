package Tephra::Command::reannotate;
# ABSTRACT: Transfer annotations from a reference set of repeats to Tephra annotations.

use 5.014;
use strict;
use warnings;
use Pod::Find     qw(pod_where);
use Pod::Usage    qw(pod2usage);
use Capture::Tiny qw(capture_merged);
use File::Path    qw(make_path remove_tree);
use Tephra -command;
use Tephra::Annotation::Transfer;

sub opt_spec {
    return (    
	[ "fasta|f=s",      "The genome sequences in FASTA format used to search for LTR-RTs "                 ],
	[ "repeatdb|d=s",   "The file of repeat sequences in FASTA format to use for classification "          ], 
	[ "outfile|o=s",    "The reannoted FASTA file of repeats "                                             ],  
	[ "threads|t=i",    "The number of threads to use for clustering coding domains (Default: 1) "         ],
	[ "percentcov|c=i", "The percent coverage cutoff for BLAST hits to the repeat database (Default: 50) " ],
	[ "percentid|p=i",  "The percent identity cutoff for BLAST hits to the repeat database (Default: 80) " ],
	[ "hitlen|l=i",     "The minimum length BLAST hits to the repeat database (Default: 80) "              ],
    );
}

sub validate_args {
    my ($self, $opt, $args) = @_;

    my $command = __FILE__;
    if ($opt->{man}) {
        system('perldoc', $command) == 0 or die $!;
        exit(0);
    }
    elsif ($opt->{help}) {
        $self->help and exit(0);
    }
    elsif (!$opt->{fasta} || !$opt->{repeatdb} || !$opt->{outfile}) {
	say STDERR "\nERROR: Required arguments not given.\n";
	$self->help and exit(0);
    }
} 

sub execute {
    my ($self, $opt, $args) = @_;

    my $some = _transfer_annotations($opt);
}

sub _transfer_annotations {
    my ($opt) = @_;

    my $fasta    = $opt->{fasta};
    my $repeatdb = $opt->{repeatdb};
    my $outfile  = $opt->{outfile};
    my $threads  = $opt->{threads} // 1;
    my $hpcov    = $opt->{percentcov} // 50;
    my $hpid     = $opt->{percentid} // 80;
    my $hlen     = $opt->{hitlen} // 80;
    
    my $anno_obj = Tephra::Annotation::Transfer->new( 
	fasta         => $fasta, 
	repeatdb      => $repeatdb, 
	outfile       => $outfile,
	threads       => $threads,
	blast_hit_cov => $hpcov,
	blast_hit_pid => $hpid,
	blast_hit_len => $hlen,
    );

    $anno_obj->transfer_annotations;
}

sub help {
    my $desc = capture_merged {
        pod2usage(-verbose => 99, -sections => "NAME|DESCRIPTION", -exitval => "noexit",
		  -input => pod_where({-inc => 1}, __PACKAGE__));
    };
    chomp $desc;
    print STDERR<<END
$desc
USAGE: tephra reannotate [-h] [-m]
    -m --man      :   Get the manual entry for a command.
    -h --help     :   Print the command usage.

Required:
    -f|fasta      :   The input repeat sequences in FASTA format that will be classified. 
    -d|repeatdb   :   The file of repeat sequences in FASTA format to use for classification. 
    -o|outfile    :   The output file of FASTA sequences that will have been reclassified.
    
Options:
    -t|threads    :   The number of threads to use for clustering coding domains (Default: 1).
    -c|percentcov :   The percent coverage cutoff for BLAST hits to the repeat database (Default: 50).
    -p|percentid  :   The percent identity cutoff for BLAST hits to the repeat database (Default: 80).
    -l|hitlen     :   The minimum length BLAST hits to the repeat database (Default: 80).

END
}


1;
__END__

=pod

=head1 NAME
                                                                       
 tephra reannotate - transfer annotations from a reference set of repeats to Tephra annotations

=head1 SYNOPSIS    

 tephra reannotate -f custom_repeats.fas -d repeatdb.fas -o ref_classified.fas

=head1 DESCRIPTION

 This subcommand takes a FASTA file of repeat sequences as input, such as those generated by Tephra,
 along with a file of reference repeat sequences, and transfer the annotations from the reference set to
 the input set.

=head1 AUTHOR 

S. Evan Staton, C<< <evan at evanstaton.com> >>

=head1 REQUIRED ARGUMENTS

=over 2

=item -f, --fasta

 The repeat sequences in FASTA format used to search against a reference set.

=item -d, --repeatdb

 The file of repeat sequences in FASTA format to use for classification.

=item -o, --outdir

 The output file of annotated repeat sequences in FASTA format.

=back

=head1 OPTIONS

=over 2

=item -t, --threads

 The number of threads to use for clustering coding domains (Default: 1).

=item -c, --percentcov

 The percent coverage cutoff for BLAST hits to the repeat database (Default: 50).

=item -p, --percentid

 The percent identity cutoff for BLAST hits to the repeat database (Default: 80).

=item -l, --hitlen

 The minimum length BLAST hits to the repeat database (Default: 80).

=item -h, --help

 Print a usage statement. 

=item -m, --man

 Print the full documentation.

=back

=cut
