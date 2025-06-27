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
my $query_interval_s = 0.1; # Increased frequency to match observed bus traffic

# These are the 5 query messages sent by the SME (master) to trigger
# data broadcasts from the CSCs (slaves).
# The data payload is based on observed traffic. The first two bytes
# are a dynamic counter/checksum. We now cycle through a list of
# known-good payloads captured from a live system.
my @query_groups = (
    { '0080' => 'e7500140000010c7', '0081' => '82500140000010c7', '0082' => '2d500140000010c7', '0083' => '48500140000010c7', '0084' => '6e500140000010c7' },
    { '0080' => 'd2900140000010c7', '0081' => 'b7900140000010c7', '0082' => '18900140000010c7', '0083' => '7d900140000010c7', '0084' => '5b900140000010c7' },
    { '0080' => '98a00140000010c7', '0081' => 'fda00140000010c7', '0082' => '52a00140000010c7', '0083' => '37a00140000010c7', '0084' => '11a00140000010c7' },
    { '0080' => '55b00140000010c7', '0081' => '30b00140000010c7', '0082' => '9fb00140000010c7', '0083' => 'fab00140000010c7', '0084' => 'dcb00140000010c7' },
    { '0080' => '0cc00140000010c7', '0081' => '69c00140000010c7', '0082' => 'c6c00140000010c7', '0083' => 'a3c00140000010c7', '0084' => '85c00140000010c7' },
    { '0080' => 'c1d00140000010c7', '0081' => 'a4d00140000010c7', '0082' => '0bd00140000010c7', '0083' => '6ed00140000010c7', '0084' => '48d00140000010c7' },
);

my $group_idx = 0;

$log->info("Querier starting. Will send query groups every $query_interval_s second(s).");

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
        my $current_group = $query_groups[$group_idx];
        $log->debug("Sending query group " . ($group_idx + 1) . "/" . scalar(@query_groups));

        # Send the 5 messages in the group, sorted by ID to be deterministic
        foreach my $id (sort keys %$current_group) {
            my $data = $current_group->{$id};
            my $cmd = "./canusb -d $device_file -s $can_speed -n 1 -i $id -j $data";
            my $result = system($cmd);
            if ($result != 0) {
                $log->error("Command failed with exit code $?: '$cmd'. Device may have disconnected.");
                last;
            }
            sleep(0.01); # Small gap between messages to mimic original bus traffic
        }
        
        $group_idx = ($group_idx + 1) % scalar(@query_groups);
        sleep($query_interval_s);
    }
    
    $log->warn("Device seems to have been disconnected. Rescanning...");
    sleep(1);
}