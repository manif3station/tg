package D2TG::Poller;

use strict;
use warnings;

sub run_once {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $transcribe_voice = $opts{transcribe_voice};

    my ( $updates, $next_offset ) = $telegram->get_updates( offset => $offset );

    for my $update (@$updates) {
        my $message = $update->{message} or next;
        my $text       = $message->{text};
        my $media_kind = _media_kind($message);

        next unless ( defined $text && length $text ) || $media_kind;

        my $chat_id = $message->{chat}{id};
        my $sender  = $message->{from}{username} // 'unknown';

        if ( $store && !$store->is_allowed($chat_id) ) {
            if ( $store->add_pending($chat_id) ) {
                print "NEW TG PENDING [$chat_id] awaiting approval\n";
            }
            next;
        }

        if ( defined $text && length $text ) {
            ( my $safe_text = $text ) =~ s/\r?\n/\\n/g;
            $safe_text =~ s/[\x00-\x08\x0B-\x1F\x7F]//g;

            print "NEW TG [$chat_id] $sender: $safe_text\n";
        }
        elsif ( $media_kind eq 'voice' && $transcribe_voice ) {
            my $file_id = $message->{voice}{file_id};
            my $transcript = eval { $transcribe_voice->( $telegram, $file_id ) };

            if ($@) {
                my $error = $@;
                $error =~ s/\n\z//;
                print STDERR "TRANSCRIBE ERROR [$chat_id] $sender: $error\n";
            }
            else {
                print "NEW TG VOICE [$chat_id] $sender: $transcript\n";
            }
        }
        else {
            print "NEW TG MEDIA [$chat_id] $sender: $media_kind\n";
        }
    }

    return ( $updates, $next_offset );
}

sub _media_kind {
    my ($message) = @_;

    return 'photo'    if $message->{photo};
    return 'document' if $message->{document};
    return 'voice'    if $message->{voice};
    return undef;
}

1;

=head1 NAME

D2TG::Poller - the long-poll loop connecting D2TG::Telegram to stdout

=head1 SYNOPSIS

    my $offset;
    while (1) {
        ( undef, $offset ) = D2TG::Poller::run_once( $telegram, $offset, $store );
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
carrying a text message or recognized media (photo/document/voice) from
an allow-listed sender, prints one line to STDOUT: the message text, or
C<NEW TG MEDIA [chat_id] sender: <type>> for photo/document (and voice
too, when no C<transcribe_voice> callback is given). A message from a
sender not yet allow-listed produces no content output at all, but does
print a one-time C<NEW TG PENDING [chat_id] awaiting approval> line the
first time that sender is recorded pending (not on subsequent messages
from the same still-pending sender). Downloading photo/document media or
replying are separate, later work.

=head1 FUNCTIONS

=head2 run_once($telegram, $offset, $store, transcribe_voice => \&coderef)

Takes a L<D2TG::Telegram>-shaped object (anything with a C<get_updates>
method matching that signature), the current offset, and an optional
L<D2TG::Store>-shaped object (anything with C<is_allowed>/C<add_pending>
methods). When C<$store> is given, a sender not in its allow-list is
recorded via C<add_pending>, printing the one-time pending notification
described above but never the message text; when omitted, every
sender's text is printed unconditionally (used by earlier tests only -
C<cli/poller> always passes a real store). Returns the raw updates array
and the next offset to pass on the following call.

C<transcribe_voice>, if given, is called as
C<< $transcribe_voice->($telegram, $file_id) >> for a voice message and
should return its transcript text (typically wiring L<D2TG::Download>
and L<D2TG::Transcribe> together). Its success prints
C<NEW TG VOICE [chat_id] sender: <transcript>> to STDOUT; its failure
prints C<TRANSCRIBE ERROR [chat_id] sender: <message>> to STDERR and the
loop continues - one bad voice note never crashes the poller. Without
C<transcribe_voice>, a voice message falls back to the plain
C<NEW TG MEDIA> line.

=cut
