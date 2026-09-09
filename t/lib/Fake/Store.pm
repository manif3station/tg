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
    my ( $self, $chat_id, $message_id, $sender, $summary, %args ) = @_;
    my $existing = $self->{messages}{$chat_id}{$message_id};
    $self->{messages}{$chat_id}{$message_id} = {
        sender     => $sender,
        summary    => $summary,
        local_path => $args{local_path} // ( $existing ? $existing->{local_path} : undef ),
    };
    return;
}

sub get_message {
    my ( $self, $chat_id, $message_id ) = @_;
    return $self->{messages}{$chat_id}{$message_id};
}

sub get_attachment_path {
    my ( $self, $chat_id, $message_id ) = @_;
    my $row = $self->{messages}{$chat_id}{$message_id};
    return $row ? $row->{local_path} : undef;
}

sub record_failed_download {
    my ( $self, $chat_id, $message_id, $file_id, %args ) = @_;

    my ($existing) = grep { $_->{chat_id} == $chat_id && $_->{message_id} == $message_id }
      @{ $self->{failed_downloads} || [] };

    if ($existing) {
        @{$existing}{qw(file_id sender media_kind caption_note error)} =
          ( $file_id, @args{qw(sender media_kind caption_note error)} );
        return $existing->{id};
    }

    my $id = ++$self->{_next_failed_download_id};
    push @{ $self->{failed_downloads} }, {
        id           => $id,
        chat_id      => $chat_id,
        message_id   => $message_id,
        file_id      => $file_id,
        sender       => $args{sender},
        media_kind   => $args{media_kind},
        caption_note => $args{caption_note},
        error        => $args{error},
    };
    return $id;
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
array of hashrefs rather than a real table, but mirroring the real
table's C<(chat_id, message_id)> upsert behavior (a second call for the
same pair refreshes the existing entry instead of duplicating it).

=cut
