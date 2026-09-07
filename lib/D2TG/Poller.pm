package D2TG::Poller;

use strict;
use warnings;

sub run_once {
    my ( $telegram, $offset, $store ) = @_;

    my ( $updates, $next_offset ) = $telegram->get_updates( offset => $offset );

    for my $update (@$updates) {
        my $message = $update->{message} or next;
        my $text = $message->{text};
        next unless defined $text && length $text;

        my $chat_id = $message->{chat}{id};
        my $sender  = $message->{from}{username} // 'unknown';

        if ( $store && !$store->is_allowed($chat_id) ) {
            $store->add_pending($chat_id);
            next;
        }

        ( my $safe_text = $text ) =~ s/\r?\n/\\n/g;

        print "NEW TG [$chat_id] $sender: $safe_text\n";
    }

    return ( $updates, $next_offset );
}

1;

=head1 NAME

D2TG::Poller - the long-poll loop connecting D2TG::Telegram to stdout

=head1 SYNOPSIS

    my $offset;
    while (1) {
        ( undef, $offset ) = D2TG::Poller::run_once( $telegram, $offset );
    }

=head1 KNOWN LIMITATION

C<SIGTERM>/C<SIGINT> are only checked between C<get_updates> calls, so
shutdown can be delayed by up to that call's long-poll timeout (default
30s) if it's mid-request when the signal arrives. Interrupting a
blocking C<HTTP::Tiny> call cleanly would need an async/select-based
rewrite, which is out of this ticket's scope - acceptable for now since
the delay is bounded and short.

=head1 DESCRIPTION

C<run_once> performs a single C<get_updates> call and, for each update
carrying a text message, prints one line to STDOUT naming the chat id,
sender, and text. Non-text updates (photos, documents, voice, etc.) are
silently skipped in this ticket's scope - handling them is separate,
later work. Access control (allow-list/pending) is likewise not applied
here - every sender's text is printed - a following ticket adds the gate
before this is used for real.

=head1 FUNCTIONS

=head2 run_once($telegram, $offset)

Takes a L<D2TG::Telegram>-shaped object (anything with a C<get_updates>
method matching that signature) and the current offset. Returns the raw
updates array and the next offset to pass on the following call.

=cut
