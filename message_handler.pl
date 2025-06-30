#!/usr/bin/perl

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use YAML::Tiny 'LoadFile';
use Redis;
use JSON::MaybeXS;
use IO::Select;
use Time::HiRes qw(time sleep);
use FindBin qw($Bin);
use lib "$Bin/lib"; # Add the 'lib' directory relative to this script
use CAN::Adapter::Lawicel; # Now it can be found

# --- Setup ---
Log::Log4perl->easy_init($INFO);
my $log = get_logger();

my $device_file = '/dev/ttyUSB0';
my $can_speed   = 500000;
my $config_file = './webapp/config.yml';

my $config = LoadFile($config_file)
    or $log->logdie("Could not load YAML from '$config_file'");

my %id_info;
foreach my $csc (keys %{ $config->{csc_ids} }) {
    foreach my $id (keys %{ $config->{csc_ids}->{$csc} }) {
        my $id_data = $config->{csc_ids}->{$csc}->{$id};
        $id_info{$id} = {
            csc        => $csc,
            type       => $id_data->{type},
            cell_map   => $id_data->{cell_map}   || undef,
            sensor_map => $id_data->{sensor_map} || undef,
        };
    }
}
$log->info("Created reverse lookup map for " . scalar(keys %id_info) . " CAN IDs.");

my $redis = Redis->new or $log->logdie("Cannot connect to Redis server");
$log->info("Connected to Redis.");

$redis->set('bms:stats:total_messages', 0);
$redis->set('bms:stats:corrupted_frames', 0);
$log->info("Redis statistics counters reset.");

# Query data, moved from querier.pl
my @query_groups = (
    { '0080' => 'e7500140000010c7', '0081' => '82500140000010c7', '0082' => '2d500140000010c7', '0083' => '48500140000010c7', '0084' => '6e500140000010c7' },
    { '0080' => 'd2900140000010c7', '0081' => 'b7900140000010c7', '0082' => '18900140000010c7', '0083' => '7d900140000010c7', '0084' => '5b900140000010c7' },
    { '0080' => '98a00140000010c7', '0081' => 'fda00140000010c7', '0082' => '52a00140000010c7', '0083' => '37a00140000010c7', '0084' => '11a00140000010c7' },
    { '0080' => '55b00140000010c7', '0081' => '30b00140000010c7', '0082' => '9fb00140000010c7', '0083' => 'fab00140000010c7', '0084' => 'dcb00140000010c7' },
    { '0080' => '0cc00140000010c7', '0081' => '69c00140000010c7', '0082' => 'c6c00140000010c7', '0083' => 'a3c00140000010c7', '0084' => '85c00140000010c7' },
    { '0080' => 'c1d00140000010c7', '0081' => 'a4d00140000010c7', '0082' => '0bd00140000010c7', '0083' => '6ed00140000010c7', '0084' => '48d00140000010c7' },
);
my $group_idx = 0;
my $last_query_time = 0;
my $query_interval_s = 0.1;

my $json_coder = JSON::MaybeXS->new(utf8 => 1);
my $message_count = 0;

# --- Main Control Loop ---
while (1) {
    # 1. Device Connection Phase
    my $adapter = CAN::Adapter::Lawicel->new(device => $device_file);
    eval { $adapter->open() };
    if ($@) {
        if ($@ =~ /Can't open/) {
            $log->warn("Device '$device_file' not found. Awaiting connection...");
        } elsif ($@ =~ /denied/) {
            $log->logdie("Device '$device_file' not readable. Please check permissions.");
        } else {
            $log->logdie("Failed to open device '$device_file': $@");
        }
        sleep(5);
        next;
    }

    eval { $adapter->open_bus(can_speed => $can_speed) };
    if ($@) {
        $log->error("Failed to open CAN bus on '$device_file': $@. Retrying...");
        $adapter->close();
        sleep(5);
        next;
    }
    $log->info("CAN adapter opened on '$device_file' at ${can_speed}bps. Starting event loop.");

    # 2. Event Loop
    while (1) {
        # A. Check if it's time to send a query
        if (time() - $last_query_time >= $query_interval_s) {
            my $current_group = $query_groups[$group_idx];
            $log->debug("Sending query group " . ($group_idx + 1));
            foreach my $id (sort keys %$current_group) {
                my $data = $current_group->{$id};
                $adapter->send(id => $id, data => $data);
                sleep(0.01); # Small gap between messages
            }
            $group_idx = ($group_idx + 1) % @query_groups;
            $last_query_time = time();
        }

        # B. Fill the buffer with any available data from the adapter.
        # This is a non-blocking read.
        my $bytes_read = $adapter->fill_buffer();
        unless (defined $bytes_read) {
            $log->warn("Adapter disconnected or read error.");
            last; # Break out of the inner event loop
        }

        # C. Process all complete frames in the buffer
        while (my $frame = $adapter->read_frame()) {
            $message_count++;
            $redis->incr('bms:stats:total_messages');

            if ($frame->{type} eq 'data') {
                my $id = $frame->{id};
                if (my $info = $id_info{$id}) {
                    my ($csc, $type) = ($info->{csc}, $info->{type});
                    my $now = time();
                    my $update_payload;
                    
                    # Main heartbeat for CSC presence detection
                    my $csc_freq_key = "bms:msg_times:$csc";
                    $redis->zremrangebyscore($csc_freq_key, '-inf', $now - 3);
                    $redis->zadd($csc_freq_key, $now, "$now:$message_count");
                    $redis->expire($csc_freq_key, 10);

                    my @bytes = @{ $frame->{data} };

                    if ($type eq 'voltage' && $info->{cell_map}) {
                        $redis->set("bms:heartbeat:voltage:$csc", $now);
                        my %voltages;
                        foreach my $start_byte (keys %{$info->{cell_map}}) {
                            my $cell_num = $info->{cell_map}->{$start_byte};
                            if (defined $bytes[$start_byte] && defined $bytes[$start_byte + 1]) {
                                my $voltage = convert_bytes_to_voltage($bytes[$start_byte], $bytes[$start_byte + 1]);
                                $voltages{$cell_num} = $voltage;
                                $redis->hset("bms:csc:$csc", $cell_num, $voltage);
                            }
                        }
                        $update_payload = { csc => $csc, id => $id, type => 'voltage', voltages => \%voltages };
                        $redis->publish('bms:updates', $json_coder->encode($update_payload));
                        $log->info("[Msg $message_count] Processed voltages for CSC $csc, ID $id");

                    } elsif ($type eq 'temperature' && $info->{sensor_map}) {
                        $redis->set("bms:heartbeat:temp:$csc", $now);
                        my %sensor_temps;
                        foreach my $byte_index (keys %{$info->{sensor_map}}) {
                            my $sensor_num = $info->{sensor_map}->{$byte_index};
                             if (defined $bytes[$byte_index]) {
                                my $temp = convert_byte_to_temp($bytes[$byte_index]);
                                $sensor_temps{$sensor_num} = $temp;
                                $redis->hset("bms:csc_temps:$csc", $sensor_num, $temp);
                            }
                        }
                        $update_payload = { csc => $csc, id => $id, type => 'temperature', temps => \%sensor_temps };
                        $redis->publish('bms:updates', $json_coder->encode($update_payload));
                        $log->trace("[Msg $message_count] Processed temperatures for CSC $csc, ID $id");
                    
                    } elsif ($type eq 'total_voltage') {
                        $redis->set("bms:heartbeat:total_v:$csc", $now);
                        if (defined $bytes[6] && defined $bytes[7]) {
                            my $val = (($bytes[6] << 8) | $bytes[7]) * 2;
                            $redis->set("bms:csc_total_v:$csc", $val);
                            $update_payload = { csc => $csc, id => $id, type => 'total_voltage', value => $val };
                            $redis->publish('bms:updates', $json_coder->encode($update_payload));
                            $log->trace("[Msg $message_count] Processed total voltage for CSC $csc, ID $id");
                        }
                    } else { # 'unknown' type
                        my $data_hex = join('', map { sprintf "%02x", $_ } @bytes);
                        $redis->hset("bms:csc_raw:$csc", $id, $data_hex);
                        $update_payload = { csc => $csc, id => $id, type => 'unknown', data => $data_hex };
                        $redis->publish('bms:updates', $json_coder->encode($update_payload));
                        $log->trace("[Msg $message_count] Stored raw data for CSC $csc, ID $id, Type $type");
                    }
                } else {
                    $log->debug("[Msg $message_count] Ignored unknown CAN ID: $id");
                }
            }
            elsif ($frame->{type} eq 'error') {
                $redis->incr('bms:stats:corrupted_frames');
                $log->warn("[Msg $message_count] Communication error: $frame->{details} (raw: $frame->{raw})");
            }
            elsif ($frame->{type} eq 'ack' || $frame->{type} eq 'nack') {
                $log->debug("[Msg $message_count] Received adapter status: $frame->{type}");
            }
        }

        # D. Sleep for a short time to prevent a busy-loop when no data is available.
        sleep(0.01);
    }

    $log->warn("Connection lost. Closing handle and rescanning...");
    $adapter->close();
    sleep(1);
}

# --- Subroutines ---
sub convert_bytes_to_voltage {
    my ($byte1, $byte2) = @_;
    # The bytes are in Big-Endian order.
    return (($byte1 << 8) | $byte2) / 1000.0;
}

sub convert_byte_to_temp {
    my ($byte) = @_;
    return $byte - 40;
}
