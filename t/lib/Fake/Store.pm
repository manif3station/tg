package Fake::Store;

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        allowed => { map { $_ => 1 } @{ $args{allowed} || [] } },
        pending => [],
    }, $class;
}

sub is_allowed {
    my ( $self, $id ) = @_;
    return $self->{allowed}{$id} ? 1 : 0;
}

sub add_pending {
    my ( $self, $id ) = @_;
    my $already = grep { $_ == $id } @{ $self->{pending} };
    push @{ $self->{pending} }, $id;
    return $already ? 0 : 1;
}

1;

=head1 NAME

Fake::Store - shared test double for D2TG::Store's access-control shape

=head1 SYNOPSIS

    my $store = Fake::Store->new( allowed => [999] );
    $store->is_allowed(999);     # 1
    $store->add_pending(111);    # 1 the first time, 0 thereafter

=head1 DESCRIPTION

C<add_pending> mirrors L<D2TG::Store>'s real return semantics (true only
the first time a given id is recorded pending) so tests asserting the
one-time C<NEW TG PENDING> notification behave correctly; a caller that
only needs "always allowed to proceed" gets the same result on a single
call per id.

=cut
