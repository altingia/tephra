package Tephra::Command::findhelitrons;
# ABSTRACT: Find Helitons in a genome assembly.

use 5.010;
use strict;
use warnings;
use File::Basename;
use Tephra -command;
use Tephra::Config::Exe;
use Tephra::Hel::HelSearch;

sub opt_spec {
    return (    
	[ "genome|g=s",           "The genome sequences in FASTA format to search for Helitrons "   ],
	[ "helitronscanner|j=s",  "The HelitronScanner .jar file (configured automatically) "       ],
	[ "outfile|o=s",          "The final combined and filtered GFF3 file of Helitrons "         ],
    );
}

sub validate_args {
    my ($self, $opt, $args) = @_;

    my $command = __FILE__;
    if ($self->app->global_options->{man}) {
	system([0..5], "perldoc $command");
    }
    elsif ($self->app->global_options->{help}) {
	$self->help;
    }
    elsif (!$opt->{genome} || !$opt->{outfile}) {
	say "\nERROR: Required arguments not given.";
	$self->help and exit(0);
    }
} 

sub execute {
    my ($self, $opt, $args) = @_;

    exit(0) if $self->app->global_options->{man} ||
	$self->app->global_options->{help};

    my $gff = _run_helitron_search($opt);
}

sub _run_helitron_search {
    my ($opt) = @_;
    
    my $genome   = $opt->{genome};
    my $hscan    = $opt->{helitronscanner};
    my $gff      = $opt->{outfile};
    my $config   = Tephra::Config::Exe->new->get_config_paths;
    my ($hscanj) = @{$config}{qw(hscanjar)};

    $hscan //= $hscanj;

    say STDERR "hscandir: $hscan";
    my $hel_search = Tephra::Hel::HelSearch->new( 
	genome  => $genome, 
	helitronscanner => $hscan,
	outfile => $gff
    );

    my $hel_seqs = $hel_search->find_helitrons;
    $hel_search->make_hscan_gff($hel_seqs);
    
    return $gff;
}

sub help {
    print STDERR<<END

USAGE: tephra findhelitrons [-h] [-m]
    -m --man                :   Get the manual entry for a command.
    -h --help               :   Print the command usage.

Required:
    -g|genome               :   The genome sequences in FASTA format to search for Helitrons.. 
    -o|outfile              :   The final combined and filtered GFF3 file of Helitrons.

Options:
    -d|helitronscanner_dir  :   The HelitronScanner directory containing the ".jar" files and Training Set.
                                This should be configured automatically upon a successful install.

END
}


1;
__END__

=pod

=head1 NAME
                                                                       
 tephra findhelitrons - Find Helitrons in a genome assembly.

=head1 SYNOPSIS    

 tephra findhelitrons -g ref.fas -o ref_helitrons.gff3

=head1 DESCRIPTION

 Find Helitionrs in a reference genome assembly.

=head1 AUTHOR 

S. Evan Staton, C<< <statonse at gmail.com> >>

=head1 REQUIRED ARGUMENTS

=over 2

=item -g, --genome

 The genome sequences in FASTA format to search for TIR TEs.

=item -o, --outfile

 The final combined and filtered GFF3 file of Helitrons.

=back

=head1 OPTIONS

=over 2

=item -d, --helitronscanner_dir

 The HelitronScanner directory. This should not have to be used except by developers as it
 should be configured automatically during the installation.

=item -h, --help

 Print a usage statement. 

=item -m, --man

 Print the full documentation.

=back

=cut
