#!/usr/bin/env perl

use 5.010;
use strict;
use warnings FATAL => 'all';
use autodie             qw(open);
use IPC::System::Simple qw(system);
use Capture::Tiny       qw(capture);
use File::Path          qw(remove_tree);
use File::Find;
use File::Spec;
#use Data::Dump;

use Test::More tests => 3;

my $devtests = 0;
if (defined $ENV{TEPHRA_ENV} && $ENV{TEPHRA_ENV} eq 'development') {
    $devtests = 1;
}

my $cmd      = File::Spec->catfile('blib', 'bin', 'tephra');
my $testdir  = File::Spec->catdir('t', 'test_data');
my $genome   = File::Spec->catfile($testdir, 'ref.fas');
my $repeatdb = File::Spec->catfile($testdir, 'repdb.fas');
my $masked   = File::Spec->catfile($testdir, 'ref_masked.fas');
my $log      = File::Spec->catfile($testdir, 'ref_masked.fas.log');

SKIP: {
    skip 'skip development tests', 3 unless $devtests;
    my @assemb_results = capture { system([0..5], "$cmd maskref -h") };

    ok(@assemb_results, 'Can execute maskref subcommand');
    
    my $mask_cmd = "$cmd maskref -g $genome -d $repeatdb -o $masked";
    #say STDERR $mask_cmd;
    
    my @ret = capture { system([0..5], $mask_cmd) };

    ok( -e $masked, 'Can mask reference' );
    ok( -e $log, 'Can mask reference' );
    
    ## clean up
    unlink $log;
};

done_testing();
