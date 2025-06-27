#!/usr/bin/perl

use strict;
use warnings;
use Redis;
use JSON::MaybeXS;
use IO::Handle;

# --- Setup ---
my $log_file = "bms_data_log.csv";
my $write_header = !-s $log_file;

open(my $log_fh, '>>', $log_file) or die "Cannot open log file '$log_file': $!";
$log_fh->autoflush(1);

if ($write_header) {
    print $log_fh "timestamp,type,csc,can_id,payload\n";
}

my $redis = Redis->new or die "Cannot connect to Redis server";
my $json_coder = JSON::MaybeXS->new(utf8 => 1);

print "Logger started. Subscribing to 'bms:updates'. Appending to $log_file...\n";

# --- Main Subscription Loop ---
$redis->subscribe('bms:updates', sub {
    my ($message, $channel) = @_;
    my $decoded = $json_coder->decode($message);
    
    my $timestamp = time();
    my $type = $decoded->{type};
    my $csc = $decoded->{csc};
    my $id = $decoded->{id};
    my $payload_str = "";
    
    if ($type eq 'voltage') {
        $payload_str = $json_coder->encode($decoded->{voltages});
    } elsif ($type eq 'temperature') {
        $payload_str = $json_coder->encode($decoded->{temps});
    } elsif ($type eq 'total_voltage') {
        $payload_str = $decoded->{value};
    } else {
        $payload_str = $decoded->{data};
    }
    
    if (defined $payload_str && $payload_str =~ /,/) {
        $payload_str = qq{"$payload_str"};
    }

    print $log_fh join(',', $timestamp, $type, $csc, $id, $payload_str) . "\n";
});