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

sub record_message {
    my ( $self, $chat_id, $message_id, $sender, $summary ) = @_;
    $self->{messages}{$chat_id}{$message_id} = { sender => $sender, summary => $summary };
    return;
}

sub get_message {
    my ( $self, $chat_id, $message_id ) = @_;
    return $self->{messages}{$chat_id}{$message_id};
}

sub record_failed_download {
    my ( $self, $chat_id, $message_id, $file_id, $error ) = @_;
    push @{ $self->{failed_downloads} }, {
        chat_id    => $chat_id,
        message_id => $message_id,
        file_id    => $file_id,
        error      => $error,
    };
    return scalar @{ $self->{failed_downloads} };
}

sub failed_downloads {
    my ($self) = @_;
    return $self->{failed_downloads} || [];
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

C<record_message>/C<get_message> (TGT-038/TGT-039) are simple in-memory
mirrors of L<D2TG::Store>'s same-named methods, keyed by
C<chat_id>+C<message_id>.

C<record_failed_download>/C<failed_downloads> (TGT-104) are simple
in-memory mirrors of L<D2TG::Store>'s same-named methods - an ordered
array of hashrefs rather than a real table, since no test needs to
remove/query them individually.

=cut
