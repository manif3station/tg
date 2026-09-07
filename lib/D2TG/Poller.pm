package D2TG::Poller;

use strict;
use warnings;

sub run_once_safe {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $sleep_fn = delete $opts{sleep} || \&_sleep;

    my $new_offset = eval {
        my ( undef, $off ) = run_once( $telegram, $offset, $store, %opts );
        $off;
    };

    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        print STDERR "POLL ERROR: $error\n";
        $sleep_fn->(2);
        return $offset;
    }

    return $new_offset;
}

sub _sleep {
    my ($seconds) = @_;
    return sleep $seconds;
}

sub run_once {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $transcribe_voice = $opts{transcribe_voice};
    my $download_media   = $opts{download_media};

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
            _print_reply_template($chat_id);
        }
        elsif ( $media_kind eq 'voice' && $transcribe_voice ) {
            my $file_id = $message->{voice}{file_id};
            my ( $ok, $transcript ) =
              _run_non_fatal( $transcribe_voice, $telegram, $file_id, $chat_id, $sender, 'TRANSCRIBE ERROR' );

            if ($ok) {
                print "NEW TG VOICE [$chat_id] $sender: $transcript\n";
                _print_reply_template($chat_id);
            }
        }
        elsif ( ( $media_kind eq 'photo' || $media_kind eq 'document' ) && $download_media ) {
            my $file_id = _media_file_id( $message, $media_kind );
            my ( $ok, $local_path ) =
              _run_non_fatal( $download_media, $telegram, $file_id, $chat_id, $sender, 'MEDIA DOWNLOAD ERROR' );

            if ($ok) {
                print "NEW TG MEDIA [$chat_id] $sender: $media_kind $local_path\n";
                _print_reply_template($chat_id);
            }
        }
        else {
            print "NEW TG MEDIA [$chat_id] $sender: $media_kind\n";
            _print_reply_template($chat_id);
        }
    }

    return ( $updates, $next_offset );
}

sub _print_reply_template {
    my ($chat_id) = @_;
    print qq{REPLY WITH: d2 tg.reply $chat_id "..."\n};
    return;
}

sub _media_kind {
    my ($message) = @_;

    return 'photo'    if $message->{photo};
    return 'document' if $message->{document};
    return 'voice'    if $message->{voice};
    return undef;
}

sub _run_non_fatal {
    my ( $coderef, $telegram, $file_id, $chat_id, $sender, $error_prefix ) = @_;

    my $result = eval { $coderef->( $telegram, $file_id ) };

    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        print STDERR "$error_prefix [$chat_id] $sender: $error\n";
        return ( 0, undef );
    }

    return ( 1, $result );
}

sub _media_file_id {
    my ( $message, $media_kind ) = @_;

    return $media_kind eq 'document'
      ? $message->{document}{file_id}
      : $message->{photo}[-1]{file_id};
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
too, when no C<transcribe_voice> callback is given; photo/document too,
when no C<download_media> callback is given). A message from a sender
not yet allow-listed produces no content output at all, but does print a
one-time C<NEW TG PENDING [chat_id] awaiting approval> line the first
time that sender is recorded pending (not on subsequent messages from
the same still-pending sender). Replying is separate, later work.

=head1 FUNCTIONS

=head2 run_once_safe($telegram, $offset, $store, sleep => \&coderef, %run_once_opts)

Wraps C<run_once> so a transient failure (e.g. a network blip inside
C<get_updates>) never kills the caller's loop - see TGT-028, a real
production incident where an uncaught exception here silently ended the
whole poller process. On success, behaves exactly like calling
C<run_once> and taking its offset. On failure: strips the trailing
newline from C<$@>, prints C<POLL ERROR: <message>> to STDERR, sleeps 2
seconds (via C<sleep>, injectable for tests; defaults to a real
C<sleep>) to avoid hammering a persistently-failing endpoint, and
returns the I<unchanged> C<$offset> so the next call retries from the
same place. All other C<%opts> (C<transcribe_voice>, C<download_media>)
pass through to C<run_once> unchanged.

=head2 run_once($telegram, $offset, $store, transcribe_voice => \&coderef, download_media => \&coderef)

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

C<download_media>, if given, is called as
C<< $download_media->($telegram, $file_id) >> for a photo or document
message and should return the local path it was downloaded to (typically
wrapping L<D2TG::Download>). For a photo, C<$file_id> is taken from the
I<last> entry of Telegram's C<photo> array (Telegram lists C<PhotoSize>
entries smallest-first, so the last is the largest); for a document, it
is C<< $message->{document}{file_id} >> directly. Success prints
C<NEW TG MEDIA [chat_id] sender: <type> <local_path>> to STDOUT; failure
prints C<MEDIA DOWNLOAD ERROR [chat_id] sender: <message>> to STDERR and
the loop continues, matching C<transcribe_voice>'s non-fatal handling.
Without C<download_media>, photo/document messages fall back to the
plain C<NEW TG MEDIA> line.

C<_run_non_fatal> is the shared internal helper both of the above use:
it evals a callback, and on failure strips the trailing newline from
C<$@> and prints C<< <error_prefix> [chat_id] sender: <message> >> to
STDERR, returning C<(0, undef)>; on success it returns
C<(1, $result)>. The caller is responsible for printing its own
differently-shaped success line.

Every content line (text, a successfully transcribed voice message, or a
successfully/plainly reported photo/document) is immediately followed by
a C<< REPLY WITH: d2 tg.reply <chat_id> "..." >> line - a ready-to-run
reply command template with the chat id filled in, per the owner's
answered design question (Q-004). This is only ever a template: nothing
in this module ever calls L<D2TG::Reply> or sends a reply itself. The
pending-notification line and the two C<*ERROR> lines never get one -
there is nothing to reply to yet.

=cut
