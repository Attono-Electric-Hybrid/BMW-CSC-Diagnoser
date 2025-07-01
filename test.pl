#!/usr/bin/perl

use strict;
use warnings;
# Make sure our local lib is in the path
use FindBin qw($Bin);
use lib "$Bin/lib";
use Data::Dumper;

use Time::HiRes qw(time sleep);
use CAN::Adapter::Lawicel;

my $device = '/dev/ttyUSB0';
   my $adapter = CAN::Adapter::Lawicel->new(device => $device);
print Data::Dumper->Dump([$adapter]);
