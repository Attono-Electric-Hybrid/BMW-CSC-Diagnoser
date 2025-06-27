package CAN::Adapter::Lawicel;

use 5.006;
use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

CAN::Adapter::Lawicel - Interface to Lawicel-style CAN USB adapters.

=head1 VERSION

Version 0.01

=cut


=head1 SYNOPSIS

    use CAN::Adapter::Lawicel;

    my $adapter = CAN::Adapter::Lawicel->new(
        device => '/dev/ttyUSB0',
    );

    # ... more to come

=head1 SUBROUTINES/METHODS

=head2 new

Creates a new adapter object.

=over

=item * C<device>

The path to the serial device (e.g., '/dev/ttyUSB0').

=item * C<baudrate>

The serial baud rate for the adapter. Defaults to 2000000.

=back

sub new {
    my ($class, %args) = @_;

    my $self = {
        device   => $args{device}   || '/dev/ttyUSB0',
        baudrate => $args{baudrate} || 2000000,
        handle   => undef, # Will hold the serial port handle
    };

    return bless $self, $class;
}

=head1 AUTHOR

Gemini Code Assist

=cut

1;