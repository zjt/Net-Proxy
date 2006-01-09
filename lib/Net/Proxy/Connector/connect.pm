package Net::Proxy::Connector::connect;
use strict;
use warnings;
use Carp;

use Net::Proxy::Connector;
our @ISA = qw( Net::Proxy::Connector );

sub init {
    my ($self) = @_;

    # check params
    for my $attr (qw( host port )) {
        croak "$attr parameter is required"
            if !exists $self->{$attr};
    }

    # create a user agent class linked to this connector
    my $id = refaddr $self;
    require LWP::UserAgent;
    {
        no warnings;
        eval << "END_PACKAGE";
package LWP::UserAgent::$id;
our \@ISA = qw( LWP::UserAgent );
sub get_basic_credentials {
    return ( \$self->{proxy_user}, \$self->{proxy_pass} );
}
END_PACKAGE
    }

    $self->{agent} = my $ua = "LWP::UserAgent::$id"->new(
        agent      => $self->{proxy_agent},
        keep_alive => 1,
    );

    # set the agent proxy
    if ( $self->{proxy_host} ) {
        $self->{proxy_port} ||= 8080;
        $ua->proxy(
            http => "http://$self->{proxy_host}:$self->{proxy_port}/" );
    }
    else {
        $self->{agent}->env_proxy();
    }

    # no proxy defined!
    croak 'proxy_host parameter is required' unless $ua->proxy('http');

    return $self;
}

# IN

# OUT
sub connect {
    my ($self) = (@_);

    # connect to the proxy
    my $req = HTTP::Request->new(
        CONNECT => "http://$self->{host}:$self->{port}/" );
    my $res = $self->{agent}->request($req);

    # FIXME - Not sure about this
    require LWP::Authen::Ntlm
        if grep {/NTLM/} $res->headers()->header('WWW-Authenticate');

    # authentication failed
    die $res->status_line() if !$res->is_success();

    # the socket connected to the proxy
    return $res->{client_socket};
}

# READ
*read_from = \&Net::Proxy::Connector::raw_read_from;

# WRITE
*write_to = \&Net::Proxy::Connector::raw_write_to;

1;

__END__

=head1 NAME

Net::Proxy::Connector::connect - Create CONNECT tunnels through HTTP proxies

=head1 DESCRIPTION

C<Net::Proxy::Connecter::connect> is a C<Net::Proxy::Connector> that
uses the HTTP CONNECT method to ask the proxy to create a tunnel to
an outside server.

Be aware that some proxies are set up to deny the creation of some
outside tunnels (either to ports other than 443 or outside a specified
set of outside hosts).

This connector is only an "out" connector.

=head1 CONNECTOR OPTIONS

C<Net::Proxy::Connector::connect> accepts the following options:

=head1 C<out>

=over 4

=item * host

The destination host.

=item * port

The destination port.

=item * proxy_host

The web proxy name or address.

=item * proxy_port

The web proxy port.

=item * proxy_user

The authentication username for the proxy.

=item * proxy_pass

The authentication password for the proxy.

=item * proxy_agent

The user-agent string to use when connecting to the proxy.

=back

=head1 AUTHOR

Philippe 'BooK' Bruhat, C<< <book@cpan.org> >>.

=head1 HISTORY

This module is based on my script C<connect-tunnel>, that provided
a command-line interface to create tunnels though HTTP proxies.
It was first published on CPAN on March 2003.

A better version of C<connect-tunnel> (using C<Net::Proxy>) is provided
this distribution.

=head1 COPYRIGHT & LICENSE

Copyright 2006 Philippe 'BooK' Bruhat, All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
