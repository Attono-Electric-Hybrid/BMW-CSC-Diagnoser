#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes qw(sleep);
use FindBin qw($Bin);
use IO::Handle;

my $file = "$Bin/sample.txt";

open my $fh, '<', $file or die "Could not open file '$file': $!";

# Read all lines into memory.
my @lines = <$fh>;
close $fh;

die "Source file '$file' is empty." unless @lines;

# Infinite loop to provide a constant stream.
while (1) {
    for my $line (@lines) {
        print $line;
        STDOUT->flush();
        sleep(0.01);
    }
}