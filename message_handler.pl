#!/usr/bin/perl
use strict;
use warnings;
use IPC::Shareable;
use Log::Log4perl qw(:easy);
use FindBin qw($Bin);
use YAML::Tiny;

Log::Log4perl->easy_init($TRACE);
my $log = Log::Log4perl->get_logger('BMW::CSC::MessageHandler');

# --- Load CSC ID Configuration from YAML ---
my $config_file = "$Bin/webapp/config.yml"; 
my $config;

eval {
    my $yaml_docs = YAML::Tiny->read($config_file);
    # The parsed data is the first document in the file.
    $config = $yaml_docs->[0];
};
if ($@ || !defined($config)) {
    $log->logdie("FATAL: Could not read or parse YAML config file '$config_file': " . ($@ || 'File is empty'));
}

$log->info("Successfully loaded CSC ID configuration from $config_file");

# --- In-memory ID info map for fast lookups ---
my %id_info;
foreach my $csc (keys %{ $config->{csc_ids} }) {
    foreach my $id (keys %{ $config->{csc_ids}->{$csc} }) {
        my $id_data = $config->{csc_ids}->{$csc}->{$id};
        $id_info{$id} = {
            csc      => $csc,
            type     => $id_data->{type},
            # Store the cell_map if it exists for this ID
            cell_map => $id_data->{cell_map} || undef,
        };
    }
}
$log->info("Created reverse lookup map for " . scalar(keys %id_info) . " CAN IDs.");

# --- Shared Memory Setup ---
my %can_data_structure;
my $glue = 'bmwcsc';
my $shareable_handle = tie %can_data_structure, 'IPC::Shareable', $glue, {
    create  => 1,
    destroy => 1,
} or $log->logdie("FATAL: Could not create shared memory segment '$glue': $!");
$log->info("Tied shared memory segment '$glue' to data structure.");

open(my $child_handle, "-|", "$Bin/spew_test_data.pl") || $log->logdie("$0: can't open data source for reading: $!");

# --- Main Processing Loop ---
# Reads and processes CAN data from the child process stream.
while (my $line = <$child_handle>) {
    # Attempt to parse the CAN message line using a regular expression.
    if ($line =~ /Frame ID: (\S+),\s+Data:\s+(.*)/) {
        my $id   = uc($1);
        my $data = $2;
        chomp $data;

        # Look up ID info (CSC, type, etc.) using the pre-built map.
        if (my $info = $id_info{$id}) {
            my $csc  = $info->{csc};
            my $type = $info->{type};

            # Lock the shared memory segment for a write operation.
            $shareable_handle->shlock();

            if ($type eq 'voltage' && $info->{cell_map}) {
                # --- Voltage Message Processing ---
                my @bytes = split /\s+/, $data;
                my %cell_voltages;

                # Iterate through the cell map for this ID from our config.
                foreach my $start_byte (keys %{ $info->{cell_map} }) {
                    my $cell_num = $info->{cell_map}->{$start_byte};
                    my $byte1 = $bytes[$start_byte];
                    my $byte2 = $bytes[$start_byte + 1];

                    # Ensure both bytes exist before processing.
                    if (defined $byte1 && defined $byte2) {
                        my $voltage = convert_bytes_to_voltage($byte1, $byte2);
                        # Store voltage with two decimal places.
                        $cell_voltages{$cell_num} = sprintf("%.2f", $voltage);
                    }
                }

                # Update shared memory with the processed voltage map.
                $can_data_structure{$csc}{$id} = {
                    voltages  => \%cell_voltages,
                    type      => $type,
                    timestamp => time(),
                };
                $log->trace("Processed voltages for CSC $csc, ID $id");

            } else {
                # --- Non-Voltage Message Processing ---
                # For "unknown" types, store the raw data string as before.
                $can_data_structure{$csc}{$id} = {
                    data      => $data,
                    type      => $type,
                    timestamp => time(),
                };
                $log->trace("Stored raw data for CSC $csc, ID $id, Type $type");
            }

            # Unlock the memory.
            $shareable_handle->shunlock();

        } else {
            $log->debug("Ignored unknown CAN ID: $id");
        }
    } else {
        chomp $line;
        $log->warn("Could not parse line from child: '$line'");
    }
}
# --- Child Exit Handling ---
# The code reaches here only after the while loop exits, which happens
# when the child process terminates and the pipe is closed.
close $child_handle;

my $child_exit_status = $? >> 8;
$log->info("Child process has exited. Exit code: $child_exit_status");

sub convert_bytes_to_voltage {
    my ($byte1_hex, $byte2_hex) = @_;

    # 1. Convert each byte from hex to a decimal number.
    my $dec1 = hex($byte1_hex);
    my $dec2 = hex($byte2_hex);

    # 2. Concatenate the numbers as strings (second number first).
    my $concatenated = $dec2 . $dec1;

    # 3. Conditional: If > 9999, place a decimal point after the 4th digit.
    if ($concatenated > 9999) {
        substr($concatenated, 4, 0, '.');
    }

    # 4. Divide by 1000.
    my $divided = $concatenated / 1000;

    # 5. Add 2.
    my $final_voltage = $divided + 2;

    return $final_voltage;
}

exit 0;