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
# Iterate through each CSC in the config.
foreach my $csc (keys %{ $config->{csc_ids} }) {
    # Iterate through each ID within that CSC.
    foreach my $id (keys %{ $config->{csc_ids}->{$csc} }) {
        # Store the CSC and type for this ID.
        $id_info{$id} = {
            csc  => $csc,
            type => $config->{csc_ids}->{$csc}->{$id}->{type},
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
        my $id   = uc($1); # Normalize ID to uppercase
        my $data = $2;
        chomp $data;

        # Look up ID info (CSC and type) using the pre-built map.
        if (my $info = $id_info{$id}) {
            my $csc  = $info->{csc};
            my $type = $info->{type};

            # Lock the shared memory segment for a write operation.
            $shareable_handle->shlock();

            # Update the data structure, now including the 'type'.
            $can_data_structure{$csc}{$id} = {
                data      => $data,
                type      => $type,
                timestamp => time(),
            };

            # Unlock the memory.
            $shareable_handle->shunlock();

            $log->trace("Updated CSC $csc, ID $id, Type $type");

        } else {
            # Log if the ID is not in our configuration file.
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

exit 0;