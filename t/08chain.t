use strict;
use warnings;
use Test::More;
use Net::Proxy::Message;
use Net::Proxy::Block;

my $start;

package Net::Proxy::Block::test;
use Test::More;

our @ISA = qw( Net::Proxy::Block );
__PACKAGE__->build_instance_class();

sub init {
    my ($self) = @_;
    $self->{name} ||= '<unnamed>';
    ok( 1, "$self->{name}->init() called" );
}

sub START {
    my ( $self, $message, $from, $direction ) = @_;
    is( $message->{type}, 'START',
        "$self->{name} got message START ($direction)" );
    return $message;    # pass it on
}

sub ZLONK {
    my ( $self, $message, $from, $direction ) = @_;
    is( $message->{type}, 'ZLONK',
        "$self->{name} got message ZLONK ($direction)" );
    return Net::Proxy::Message->new( { type => 'ABORT' } );    # stop now
}

package main;

plan tests => 5;

# build a chain of factories
my $fact1 = Net::Proxy::Block::test->new( { name => 'fact1' } );
my $fact2 = Net::Proxy::Block::test->new( );

$fact1->set_next( in => $fact2 )->set_next( in => { bam => 'kapow' } );

# START the factory chain
$fact1->process( Net::Proxy::Message->new( { type => 'START' } ),
    undef, 'in' );

$fact1->process( Net::Proxy::Message->new( { type => 'ZLONK' } ),
    undef, 'in' );
