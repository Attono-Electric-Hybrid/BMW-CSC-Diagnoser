package BMW::CSC::Diagnoser;
use Dancer2;
use Log::Log4perl qw(:easy);
use AnyEvent;
use AnyEvent::Handle;

Log::Log4perl->easy_init($TRACE);

our $VERSION = '0.1';

my $log = Log::Log4perl->get_logger('BMW::CSC::Diagnoser');

#~ my $wait_for_input = AnyEvent->io (
   #~ fh   => \*STDIN, # which file handle to check
   #~ poll => "r",     # which event to wait for ("r"ead data)
   #~ cb   => sub {    # what callback to execute
    #~ my $data = <STDIN>; # read it
	#~ $log->debug($data);
   #~ }
#~ );

#~ open(my $sort_fh, '-|', 'sort -u unsorted/*.txt')
    #~ or die "Couldn't open a pipe into sort: $!";

my $can_pipe = config->{'pipe'}; 
open(my $handle, "<", $can_pipe) || $log->logdie("$0: can't open $can_pipe for reading: $!");
my $cv = AnyEvent->condvar;
my $hdl; $hdl = new AnyEvent::Handle
   fh => $handle,
   on_error => sub {
      my ($hdl, $fatal, $msg) = @_;
      AE::log error => $msg;
      $hdl->destroy;
      $cv->send;
   },
   on_read   => sub {    # what callback to execute
    my ($handle) = @_;   # the file handle that had some data to be read
	$log->debug($handle->rbuf());
   };
	

get '/' => sub {
    template 'index' => { 'title' => 'BMW::CSC::Diagnoser' };
};



true;
