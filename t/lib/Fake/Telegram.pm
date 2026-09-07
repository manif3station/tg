package Fake::Telegram;

use strict;
use warnings;

sub new {
    my ( $class, @updates_batches ) = @_;
    return bless { batches => [@updates_batches] }, $class;
}

sub get_updates {
    my ( $self, %args ) = @_;
    my $batch = shift @{ $self->{batches} } || [];

    my $next_offset = $args{offset};
    for my $u (@$batch) {
        my $candidate = $u->{update_id} + 1;
        $next_offset = $candidate
          if !defined $next_offset || $candidate > $next_offset;
    }
    return ( $batch, $next_offset );
}

1;

=head1 NAME

Fake::Telegram - shared test double for D2TG::Telegram's polling shape

=head1 SYNOPSIS

    my $tg = Fake::Telegram->new( \@batch_one, \@batch_two );
    my ( $updates, $next_offset ) = $tg->get_updates( offset => $offset );

=head1 DESCRIPTION

Used by tests that only exercise C<D2TG::Poller::run_once>'s polling
path (not sending or downloading), which only needs C<get_updates>.
Constructed with a list of update-array "batches", one consumed per
C<get_updates> call, in order.

=cut
