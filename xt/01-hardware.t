#!/usr/bin/perl

use strict;
use warnings;

# Make sure our local lib is in the path
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Load all necessary testing and support modules
use Time::HiRes qw(time sleep);
use Test::More;
use Test::Exception; # Provides lives_ok()
use CAN::Adapter::Lawicel;

my $device = '/dev/ttyUSB0';

# More specific check to help with diagnostics
if ( !-e $device ) {
    plan skip_all => "Hardware tests skipped; device '$device' not found.";
}
if ( !-r $device ) {
    plan skip_all => "Hardware tests skipped; device '$device' not readable (check permissions).";
}
if ( !-w $device ) {
    plan skip_all => "Hardware tests skipped; device '$device' not writable (check permissions).";
}

plan tests => 3;

my $adapter;
my $version;

lives_ok {
    $adapter = CAN::Adapter::Lawicel->new(device => $device);
    $adapter->open();
} 'Adapter object created and serial port opened';

lives_ok {
    $adapter->open_bus(can_speed => 500000);
} 'Adapter opens bus using settings command';

lives_ok { $adapter->close_bus() } 'Adapter closes bus (no die)';

$adapter->close() if $adapter;