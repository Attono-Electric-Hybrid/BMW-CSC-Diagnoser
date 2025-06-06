#!/usr/bin/perl
use strict;
use warnings;
use IPC::Shareable;
use Log::Log4perl qw(:easy);
use Time::HiRes qw(usleep);

Log::Log4perl->easy_init($TRACE);
my $log = Log::Log4perl->get_logger('BMW::CSC::MessageHandler');

my %shared_data;
my $glue = 'bmwcsc'; # A key to identify the shared memory segment
my $shared = tie %shared_data, 'IPC::Shareable', $glue, { create => 1, destroy => 1 };

my $can_pipe = '/var/run/bmwcsc';
open(my $handle, "<", $can_pipe) || $log->logdie("$0: can't open $can_pipe for reading: $!");
while(1)
{
	while (<$handle>) {
		my $lines = $_;
		$log->debug($lines);
		#~ $shared->shlock(); # Lock the shared memory
		#~ $shared_data{'timestamp'} = time();
		#~ $shared->shunlock(); # Unlock the shared memory
	   };	
	usleep(10000); 
};
