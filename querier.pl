#!/usr/bin/perl

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use Time::HiRes qw(sleep);

# --- Setup ---
Log::Log4perl->easy_init($INFO);
my $log = get_logger();

my $device_file = '/dev/ttyUSB0';
my $can_speed = 500000;
my $query_interval_s = 1.0;

# These are the 5 query messages sent by the SME (master) to trigger
# data broadcasts from the CSCs (slaves).
# The data payload is based on observed traffic. The first two bytes
# appear to be a counter or checksum, but using a fixed value of 00 00
# is sufficient to elicit a response from the CSCs.
my @queries = (
    { id => '0080', data => '00000140000010c7' },
    { id => '0081', data => '00000140000010c7' },
    { id => '0082', data => '00000140000010c7' },
    { id => '0083', data => '00000140000010c7' },
    { id => '0084', data => '00000140000010c7' },
);

$log->info("Querier starting. Will send " . scalar(@queries) . " queries every $query_interval_s second(s).");

# --- Main Control Loop ---
while (1) {
    # 1. Device Discovery Phase
    unless (-e $device_file && -w $device_file) {
        $log->warn("Device '$device_file' not found or not writable. Awaiting connection...");
        sleep(5) until (-e $device_file && -w $device_file);
    }
    $log->info("Device '$device_file' detected. Starting query loop.");

    # 2. Query Loop
    while (-e $device_file && -w $device_file) {
        $log->debug("Sending query sequence...");
        foreach my $query (@queries) {
            my $cmd = "./canusb -d $device_file -s $can_speed -n 1 -i $query->{id} -j $query->{data}";
            my $result = system($cmd);
            if ($result != 0) {
                $log->error("Command failed with exit code $?: '$cmd'. Device may have disconnected.");
                last;
            }
            sleep(0.01); # Small gap between messages to mimic original bus traffic
        }
        sleep($query_interval_s);
    }
    
    $log->warn("Device seems to have been disconnected. Rescanning...");
    sleep(1);
}