package Net::Proxy;
use strict;
use warnings;
use Carp;
use Scalar::Util qw( refaddr );
use IO::Select;

our $VERSION = '0.02';

# interal socket information table
my %SOCK_INFO;
my %LISTENER;
my $SELECT;
my %PROXY;
my %STATS;

# Net::Proxy attributes
my %CONNECTOR = (
    in  => {},
    out => {},
);

#
# constructor
#
sub new {
    my ( $class, $args ) = @_;

    my $self = bless \do { my $anon }, $class;

    croak "Argument to new() must be a HASHREF" if ref $args ne 'HASH';

    for my $conn (qw( in out )) {

        # check arguments
        croak "'$conn' connector required" if !exists $args->{$conn};

        croak "'$conn' connector must be a HASHREF"
            if ref $args->{$conn} ne 'HASH';

        croak "'type' key required for '$conn' connector'"
            if !exists $args->{$conn}{type};

        # load the class
        my $class = 'Net::Proxy::Connector::' . $args->{$conn}{type};
        eval "require $class";
        croak "Couldn't load $class for '$conn' connector" if $@;

        # create and store the Connector object
        $CONNECTOR{$conn}{ refaddr $self} = $class->new( $args->{$conn} );
        $CONNECTOR{$conn}{ refaddr $self}->set_proxy($self);
    }

    return $self;
}

sub register { $PROXY{ refaddr $_[0] } = $_[0]; }
sub unregister { delete $PROXY{ refaddr $_[0] }; }

#
# The Net::Proxy attributes
#
sub in_connector  { return $CONNECTOR{in}{ refaddr $_[0] }; }
sub out_connector { return $CONNECTOR{out}{ refaddr $_[0] }; }

#
# create the socket setter/getter methods
# these are actually Net::Proxy clas methods
#
{
    my $n = 0;
    for my $attr (qw( peer connector state )) {
        no strict 'refs';
        my $i = $n;
        *{"get_$attr"} = sub { $SOCK_INFO{ refaddr $_[1] }[$i]; };
        *{"set_$attr"} = sub { $SOCK_INFO{ refaddr $_[1] }[$i] = $_[2]; };
        $n++;
    }
}

#
# create statistical methods
#
for my $info (qw( opened closed )) {
    no strict 'refs';
    *{"stat_inc_$info"} = sub {
        $STATS{ refaddr $_[0]}{$info}++;
        $STATS{total}{$info}++;
    };
    *{"stat_$info"}       = sub { $STATS{ refaddr $_[0]}{$info} || 0; };
    *{"stat_total_$info"} = sub { $STATS{total}{$info} || 0; };
}

#
# socket-related methods
#
sub add_listeners {
    my ( $class, @socks ) = @_;
    for my $sock (@socks) {
        $LISTENER{ refaddr $sock} = $sock;
    }
    return;
}

# this one will explode if $SELECT is undef
sub watch_sockets {
    my ( $class, @socks ) = @_;
    $SELECT->add(@socks);
    return;
}

sub close_sockets {
    my ( $class, @socks ) = @_;

    for my $sock (@socks) {

        # clean up connector
        my $conn = Net::Proxy->get_connector($sock);
        $conn->close($sock) if $conn->can('close');

        # count connections to the proxy "in connectors" only
        my $proxy = $conn->get_proxy();
        if( refaddr $conn == refaddr $proxy->in_connector()
            && ! _is_listener( $sock ) ) {
            $proxy->stat_inc_closed();
        }

        # clean up internal structures
        delete $SOCK_INFO{ refaddr $sock};
        delete $LISTENER{ refaddr $sock};

        # clean up sockets
        $SELECT->remove($sock);
        $sock->close();
    }

    return;
}

#
# destructor
#
sub DESTROY {
    my ($self) = @_;
    delete $CONNECTOR{in}{ refaddr $self};
    delete $CONNECTOR{out}{ refaddr $self};
}

#
# the mainloop itself
#
sub mainloop {
    my ( $class, $max_connections ) = @_;
    $max_connections ||= 0;

    # initialise the loop
    $SELECT = IO::Select->new();

    # initialise all proxies
    for my $proxy ( values %PROXY ) {
        my $in    = $proxy->in_connector();
        my @socks = $in->listen();
        Net::Proxy->add_listeners(@socks);
        Net::Proxy->watch_sockets(@socks);
        Net::Proxy->set_connector( $_, $in ) for @socks;
    }

    # loop indefinitely
    while ( my @ready = $SELECT->can_read() ) {
    SOCKET:
        for my $sock (@ready) {
            if ( _is_listener($sock) ) {
                
                # prevent new connections
                if ( Net::Proxy->stat_total_opened() == $max_connections ) {
                    $sock->close();
                    next SOCKET;
                }

                # accept the new connection and connect to the destination
                Net::Proxy->get_connector($sock)->new_connection_on($sock);
            }
            else {

                # read the data
                my $peer = Net::Proxy->get_peer($sock);
                my $data
                    = Net::Proxy->get_connector($sock)->read_from($sock);
                next SOCKET if !defined $data;

                # TODO filtering by the proxy

                Net::Proxy->get_connector($peer)->write_to( $peer, $data );
            }
        }
    }
    continue {
        last if Net::Proxy->stat_total_closed() == $max_connections;
    }

    # close the listening sockets
    Net::Proxy->close_sockets( values %LISTENER );
}

#
# helper private FUNCTIONS
#
sub _is_listener { return exists $LISTENER{ refaddr $_[0] }; }

1;

__END__

=head1 NAME

Net::Proxy - Framework for proxying network connections in many ways

=head1 SYNOPSIS

    use Net::Proxy;

    # proxy connections from localhost:6789 to remotehost:9876
    # using standard TCP connections
    my $proxy = Net::Proxy->new(
        in  => { proto => tcp, port => '6789' },
        out => { proto => tcp, host => 'remotehost', port => '9876' },
    );

    # register the proxy object
    $proxy->register();

    # and you can setup multiple proxies

    # and now proxy connections indefinitely
    Net::Proxy->mainloop();

=head1 DESCRIPTION

A C<Net::Proxy> object represents a proxy that accepts connections
and then relays the data transfered between the source and the destination.

The goal of this module is to abstract the different protocols used
to connect from the proxy to the destination. See L<AVAILABLE CONNECTORS>

=head1 METHODS

If you only intend to use C<Net::Proxy> and not write new
connectors, you only need to know about C<new()>, C<register()>
and C<mainloop()>.

=head2 Class methods

=over 4

=item new( { in => { ... }, { out => { ... } } )

Return a new C<Net::Proxy> object, with two connectors configured
as described in the hashref.

=item mainloop( $max_connections )

This method initialises all the registered C<Net::Proxy> objects
and then loops on all the sockets ready for reading, passing
the data through the various C<Net::Proxy::Connector> objets
to handle the specifics of each connection.

If C<$max_connections> is given, the proxy will stop after having fully
processed that many connections. Otherwise, this method does not return.

=item add_listeners( @sockets )

Add the given sockets to the list of listening sockets.

=item watch_sockets( @sockets )

Add the given sockets to the watch list.

=item close_sockets( @sockets )

Close the given sockets and cleanup the related internal structures.

=back

Some of the class methods are related to the socket objects that handle
the actual connections.

=over 4

=item get_peer( $socket )

=item set_peer( $socket, $peer )

Get or set the socket peer.

=item get_connector( $socket )

=item set_connector( $socket, $connector )

Get or set the socket connector (a C<Net::Proxy::Connector> object).

=item get_state( $socket )

=item set_state( $socket, $state )

Get or set the socket state. Some C<Net::Proxy::Connector> classes
may wish to use this to store some internal information about the
socket or the connection.

=back

=head2 Instance methods

=over 4

=item register()

Register a C<Net::Proxy> object so that it will be included in
the C<mainloop()> processing.

=item unregister()

Unregister the C<Net::Proxy> object.

=item in_connector()

Return the C<Net::Proxy::Connector> objet that handles the incoming
connection and handles the data coming from the "client" side.

=item out_connector()

Return the C<Net::Proxy::Connector> objet that creates the outgoing 
connection and handles the data coming from the "server" side.

=back

=head2 Statistical methods

The following methods manage some statistical information
about the individual proxies:

=over 4

=item stat_inc_opened()

=item stat_inc_closed()

Increment the "opened" or "closed" connection counter for this proxy.

=item stat_opened()

=item stat_closed()

Return the count of "opened" or "closed" connections for this proxy.

=item stat_total_opened()

=item stat_total_closed()

Return the total count of "opened" or "closed" connection across
all proxy objects.

=back

=head1 AVAILABLE CONNECTORS

All connection types are provided with the help of specialised classes.
The logic for protocol C<xxx> is provided by the C<Net::Proxy::Connector::xxx>
class.

=head2 tcp (C<Net::Proxy::Connector::tcp>)

This is the simplest possible proxy. On the "in" side, it sits waiting
for incoming connections, and on the "out" side, it connects to the
configured host/port.

=head2 dummy (C<Net::Proxy::Connector::dummy>)

This proxy does nothing. You can use it as a template for writing
new C<Net::Proxy::Connector> classes.

=head2 Summary

This table summarises all the available C<Net::Proxy::Connector>
classes and the parameters their constructors recognise.

     Connector  | in parameters   | out parameters
    ------------+-----------------+----------------
     tcp        | host            | host
                | port            | port
    ------------+-----------------+----------------
     dummy      | N/A             | N/A

=head1 AUTHOR

Philippe 'BooK' Bruhat, C<< <book@cpan.org> >>.

=head1 BUGS

Please report any bugs or feature requests to
C<bug-net-proxy@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/>. I will be notified, and then you'll automatically
be notified of progress on your bug as I make changes.

=head1 TODO

Here's my own wishlist:

=over 4

=item *

port C<connect-tunnel> to use C<Net::Proxy>.

This requires writing C<Net::Proxy::Connector::connect>.

=item *

port C<sslh> (unreleased reverse proxy that can listen on a port and
proxy to a SSH server or a HTTPS server depending on the client) to
use C<Net::Proxy>.

This requires writing C<Net::Proxy::Connector::dual>.

=item *

write a script fully compatible with GNU httptunnel
(L<http://www.nocrew.org/software/httptunnel.html>.

This requires writing C<Net::Proxy::Connector::httptunnel>.

=item *

enhance the httptunnel protocol to support multiple connections

This requires writing C<Net::Proxy::Connector::httptunnel2>
(or whatever I may call it then).

=item *

Add support for filters, so that the data can be transformed on the fly
(could be useful to deceive intrusion detection systems, for example).

=back

=head1 COPYRIGHT & LICENSE

Copyright 2006 Philippe 'BooK' Bruhat, All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

