package D2TG::Poller;

use strict;
use warnings;
use POSIX qw(strftime);
use D2TG::Config;

use constant TELEGRAM_GETFILE_MAX_BYTES => 20 * 1024 * 1024;

sub run_once_safe {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $sleep_fn = delete $opts{sleep} || \&_sleep;

    my $new_offset = eval {
        my ( undef, $off ) = run_once( $telegram, $offset, $store, %opts );
        $off;
    };

    if ($@) {
        my $error = $@;
        unless ( D2TG::Config::is_transient_error($error) ) {
            $error =~ s/\n\z//;
            print STDERR "POLL ERROR: $error\n";
        }
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
    my $bot_token        = $opts{bot_token};

    my ( $updates, $next_offset ) = $telegram->get_updates( offset => $offset );

    for my $update (@$updates) {
        my $message = $update->{message} or next;
        my $text       = $message->{text};
        my $media_kind = _media_kind($message);

        next unless ( defined $text && length $text ) || $media_kind;

        my $chat_id = $message->{chat}{id};
        my $sender  = _display_name( $chat_id, $message->{from}{username} );

        my $ts = _timestamp_prefix($message);

        if ( $store && !$store->is_allowed($chat_id) ) {
            if ( $store->add_pending($chat_id) ) {
                print "$ts NEW TG PENDING [$chat_id] awaiting approval\n";
            }
            next;
        }

        my $reply_ctx  = _reply_context_suffix( $message, $store, $chat_id );
        my $message_id = $message->{message_id};
        my $msg_note   = defined $message_id ? " (msg #$message_id)" : '';

        # TGT-092 (live production incident): a photo/document's caption
        # was never read at all - Telegram's Bot API attaches it as a
        # field separate from $message->{text} (which is only present
        # for plain text messages), so it was silently dropped.
        my $caption = $message->{caption};
        my $caption_note =
          defined $caption && length $caption
          ? ' - caption: ' . _sanitize_for_stdout($caption)
          : '';

        if ( defined $text && length $text ) {
            my $safe_text = _sanitize_for_stdout($text);

            print "$ts NEW TG [$chat_id] $sender: $safe_text$msg_note$reply_ctx\n";
            _print_reply_template( $chat_id, $message_id, $bot_token );
            $store->record_message( $chat_id, $message_id, $sender, $safe_text )
              if $store && defined $message_id;
        }
        elsif ( $media_kind eq 'voice' && $transcribe_voice ) {
            my $file_id = $message->{voice}{file_id};
            my ( $ok, $transcript ) =
              _run_non_fatal( $transcribe_voice, $telegram, $file_id, $chat_id, $sender, 'TRANSCRIBE ERROR' );

            if ($ok) {
                my $safe_transcript = _sanitize_for_stdout($transcript);

                print "$ts NEW TG VOICE [$chat_id] $sender: $safe_transcript$msg_note$reply_ctx\n";
                _print_reply_template( $chat_id, $message_id, $bot_token );
                $store->record_message( $chat_id, $message_id, $sender, $safe_transcript )
                  if $store && defined $message_id;
            }
        }
        elsif ( ( $media_kind eq 'photo' || $media_kind eq 'document' ) && $download_media ) {
            my $file_id   = _media_file_id( $message, $media_kind );
            my $file_size = _media_file_size( $message, $media_kind );

            if ( defined $file_size && $file_size > TELEGRAM_GETFILE_MAX_BYTES ) {
                my $mb = sprintf( '%.1f', $file_size / 1024 / 1024 );
                print STDERR "MEDIA DOWNLOAD ERROR [$chat_id] $sender: file too large to download "
                  . "(${mb}MB, Telegram's Bot API getFile limit is 20MB)\n";
            }
            else {
                my ( $ok, $local_path ) =
                  _run_non_fatal( $download_media, $telegram, $file_id, $chat_id, $sender, 'MEDIA DOWNLOAD ERROR' );

                if ($ok) {
                    print "$ts NEW TG MEDIA [$chat_id] $sender: $media_kind $local_path$caption_note$msg_note$reply_ctx\n";
                    _print_reply_template( $chat_id, $message_id, $bot_token );
                    $store->record_message( $chat_id, $message_id, $sender, "$media_kind $local_path$caption_note" )
                      if $store && defined $message_id;
                }
            }
        }
        else {
            print "$ts NEW TG MEDIA [$chat_id] $sender: $media_kind$caption_note$msg_note$reply_ctx\n";
            _print_reply_template( $chat_id, $message_id, $bot_token );
        }
    }

    return ( $updates, $next_offset );
}

sub _display_name {
    my ( $chat_id, $username ) = @_;

    my $owner_chat_id = D2TG::Config::chat_id();
    my $owner_name    = D2TG::Config::owner_name();

    if (   defined $chat_id
        && defined $owner_chat_id
        && $chat_id eq $owner_chat_id
        && defined $owner_name
        && length $owner_name )
    {
        return $owner_name;
    }

    return $username // 'unknown';
}

sub _reply_context_suffix {
    my ( $message, $store, $chat_id ) = @_;

    my $original = $message->{reply_to_message};
    return '' unless $original;

    my $original_sender    = _display_name( $chat_id, $original->{from}{username} );
    my $original_message_id = $original->{message_id};
    my $id_note = defined $original_message_id ? " [msg #$original_message_id]" : '';

    my $what = _stored_summary( $store, $chat_id, $original_message_id );

    unless ( defined $what ) {
        my $original_text = $original->{text};
        if ( defined $original_text && length $original_text ) {
            my $safe = _sanitize_for_stdout($original_text);
            $safe = substr( $safe, 0, 5000 ) . '...' if length $safe > 5000;
            $what = $safe;
        }
        else {
            $what = _media_kind($original) // 'message';
        }
    }

    return qq{ (replying to $original_sender$id_note: $what)};
}

sub _stored_summary {
    my ( $store, $chat_id, $message_id ) = @_;

    return undef unless $store && defined $chat_id && defined $message_id;

    my $stored = $store->get_message( $chat_id, $message_id );

    return $stored ? $stored->{summary} : undef;
}

sub _timestamp_prefix {
    my ($message) = @_;

    my $epoch = $message->{date} // time;

    return '[' . strftime( '%Y-%m-%d %H:%M:%S', localtime($epoch) ) . ']';
}

sub _sanitize_for_stdout {
    my ($text) = @_;

    ( my $safe = $text ) =~ s/\r?\n/\\n/g;
    $safe =~ s/[\x00-\x08\x0B-\x1F\x7F]//g;

    return $safe;
}

sub _print_reply_template {
    my ( $chat_id, $message_id, $bot_token ) = @_;

    # TGT-086: never print the real token here - this line reaches the
    # target project's tira.policy.bridge as a monitor-output event
    # (visible to anyone who can read that board), and the token is a
    # real credential (whoever has it can send/receive as that bot).
    # Masked the same way D2TG::Config::masked_token already masks the
    # startup line (TGT-045); the placeholder <MASKED> is intentionally
    # not runnable as-is - see this template's own POD.
    my $bot_flag =
      defined $bot_token
      ? ' --bot ' . D2TG::Config::masked_token($bot_token)
      : '';
    my $reply_flag = defined $message_id ? " --reply-to-message-id $message_id" : '';
    print qq{REPLY WITH: d2 tg.reply $chat_id "..."$bot_flag$reply_flag\n};
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

sub _media_file_size {
    my ( $message, $media_kind ) = @_;

    return $media_kind eq 'document'
      ? $message->{document}{file_size}
      : $message->{photo}[-1]{file_size};
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
shutdown can be delayed if it's mid-request when the signal arrives.
TGT-035 (a real production incident: this bound previously did not
actually exist - L<D2TG::Telegram>'s default L<LWP::UserAgent> had no
explicit timeout, so a single call could block for up to LWP's own
180s default, not the 30s this section used to claim) fixed the actual
enforcement: D2TG::Telegram's default C<ua> now has an explicit hard
timeout (C<DEFAULT_HARD_TIMEOUT>, 50s as of TGT-066 - originally 35s).
TGT-044 (a second real production incident - LWP's own timeout
did not actually cover a request stuck in the TCP C<connect()> phase,
which not even C<SIGTERM> could interrupt) closed that remaining gap
with an explicit C<SIGALRM>-based hard timeout inside C<_call> itself -
so this delay is now genuinely bounded to C<DEFAULT_HARD_TIMEOUT> in
every case, not merely assumed to be. Interrupting the blocking HTTP call mid-flight
(rather than bounding its maximum duration) would still need an async/
select-based rewrite, which remains out of scope - acceptable now that
the bound is short and actually enforced end to end.

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
C<run_once> and taking its offset. On failure: if
L<D2TG::Config/is_transient_error> says the error looks transient (a
network timeout or a 5xx status), nothing is printed at all - the retry
loop below already recovers on its own, and printing it would only be
noise reaching the project's C<tira.policy.bridge> as a separate
C<monitor-output> event per occurrence (TGT-097, a live user request:
I<"instead of showing the polling error, just silent it ... and focus on
recovery instead">). Otherwise (a genuinely unexpected/non-transient
failure), strips the trailing newline from C<$@> and prints C<POLL
ERROR: <message>> to STDERR as before. Either way, sleeps 2 seconds (via
C<sleep>, injectable for tests; defaults to a real C<sleep>) to avoid
hammering a persistently-failing endpoint, and returns the I<unchanged>
C<$offset> so the next call retries from the same place. All other
C<%opts> (C<transcribe_voice>, C<download_media>) pass through to
C<run_once> unchanged.

=head2 run_once($telegram, $offset, $store, transcribe_voice => \&coderef, download_media => \&coderef, bot_token => $token)

Takes a L<D2TG::Telegram>-shaped object (anything with a C<get_updates>
method matching that signature), the current offset, and an optional
L<D2TG::Store>-shaped object (anything with C<is_allowed>/C<add_pending>
methods). When C<$store> is given, a sender not in its allow-list is
recorded via C<add_pending>, printing the one-time pending notification
described above but never the message text; when omitted, every
sender's text is printed unconditionally (used by earlier tests only -
C<cli/poller.pl> always passes a real store). Returns the raw updates array
and the next offset to pass on the following call.

Every printed sender name (the main content line and any reply-context
suffix) goes through L</_display_name> (TGT-079, a live user request):
a message from the L<D2TG::Config/chat_id> chat shows
L<D2TG::Config/owner_name> (C<D2TG_OWNER>) instead of the sender's raw
Telegram username, when that env var is set - purely a display
preference, with no effect on access control.

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

If the message carries a caption (TGT-092, a live production incident:
a caption was silently dropped entirely before this fix, causing a real
miscommunication - C<$message->{caption}> is a field the Bot API
attaches to photo/document messages, separate from C<$message->{text}>,
which is only present for plain text messages), it is sanitized the
same way inbound text already is (TGT-039) and appended to both the
printed C<NEW TG MEDIA> line (as C<- caption: <text>>) and the stored
message summary. A message with no caption - the common case - is
completely unaffected. This applies to both the C<download_media>
success path above and the plain fallback C<NEW TG MEDIA> line below.

Before calling C<download_media> at all, if the message's own declared
C<file_size> exceeds C<TELEGRAM_GETFILE_MAX_BYTES> (20MB, TGT-037 - a
live bug report: Telegram's Bot API C<getFile> endpoint has a hard,
documented 20MB limit and returns an opaque C<400 Bad Request> for
anything larger), C<download_media> is never called at all - a specific
C<MEDIA DOWNLOAD ERROR [chat_id] sender: file too large to download
(<N>MB, Telegram's Bot API getFile limit is 20MB)> is printed to STDERR
instead, so the operator can tell this apart from a genuine bug at a
glance. A message with no declared C<file_size> (Telegram does not
always send one) falls through to the normal download attempt
unaffected.

C<_sanitize_for_stdout> (TGT-039) is applied to inbound text I<and> a
successfully transcribed voice message before either is printed or
stored via C<record_message>: it escapes any C<\r>/C<\n> to a literal
C<\n> and strips other control characters, so a C<NEW TG>/C<NEW TG
VOICE> line - whose content may otherwise legitimately span multiple
lines, e.g. whisper's own per-segment output for a longer voice note -
is always exactly one stdout line, matching what every downstream
consumer (a Tira monitor job's feeder) requires.

C<_run_non_fatal> is the shared internal helper both of the above use:
it evals a callback, and on failure strips the trailing newline from
C<$@> and prints C<< <error_prefix> [chat_id] sender: <message> >> to
STDERR, returning C<(0, undef)>; on success it returns
C<(1, $result)>. The caller is responsible for printing its own
differently-shaped success line.

Every **stdout** event line (C<NEW TG>/C<NEW TG VOICE>/C<NEW TG
MEDIA>/C<NEW TG PENDING>) is prefixed with a C<[YYYY-MM-DD HH:MM:SS]>
timestamp (TGT-061, see C<_timestamp_prefix>), sourced from Telegram's
own C<message.date> field rather than local wall-clock time - it
reflects when Telegram itself received the message, not when this
poller happened to process it, which can lag behind by a poll cycle or
more. The C<TRANSCRIBE ERROR>/C<MEDIA DOWNLOAD ERROR> **stderr** lines
above are NOT timestamped (TGT-065) - C<_run_non_fatal> and the
oversized-file branch never receive or use C<$ts>.

Every content line also names the message's own C<message_id> as
C<< (msg #N) >> (TGT-040), when Telegram provided one.

Every content line (text, a successfully transcribed voice message, or a
successfully/plainly reported photo/document) is immediately followed by
a C<< REPLY WITH: d2 tg.reply <chat_id> "..." [--bot <token>] --reply-to-message-id <id> >>
line - a ready-to-run reply command template with the chat id and
message id filled in, per the owner's answered design question (Q-004).
The C<--reply-to-message-id> flag (TGT-040) is only included when
C<message_id> is known. C<--bot <masked_token>> (TGT-057) is only
included when C<bot_token> is given to C<run_once> - C<cli/poller.pl> passes
its own receiving bot's token here whenever it's running in multi-bot
mode (TGT-049), since C<d2 tg.reply>'s C<D2TG_TOKEN> fallback can't know
which of a pool of bots to use; single-bot/env-only mode never passes
C<bot_token>, so its template is unchanged. The token is masked (TGT-086,
via L<D2TG::Config/masked_token>, the same masking C<cli/poller.pl>'s own
startup line already uses, TGT-045) rather than printed in full - this
line reaches the target project's C<tira.policy.bridge> as a
C<monitor-output> event on a shared board, and the real token is a
credential, not something safe to broadcast there on every inbound
message. This means the printed C<--bot> value in multi-bot mode is not
directly runnable as-is; whoever runs C<d2 tg.reply> for that chat must
supply the real token themselves. Passing C<--reply-to-message-id>
through to C<d2 tg.reply> makes the resulting reply thread natively under
the original message in Telegram's
UI. This is only ever a template: nothing in this module ever calls
L<D2TG::Reply> or sends a reply itself. The pending-notification line and
the two C<*ERROR> lines never get one - there is nothing to reply to yet.

If Telegram's C<reply_to_message> field is present on the message (the
sender used Telegram's native reply-to-message feature), every content
line above also gets a C<< (replying to <sender> [msg #N]: <snippet-or-
kind>) >> suffix (TGT-029, message id added TGT-041), naming who/what
the reply targets: the original sender's username, that message's own
C<message_id> (omitted, along with its brackets, only if Telegram's
payload didn't carry one), and a description of the original message. A
message with no C<reply_to_message> gets no suffix at all. See
C<_reply_context_suffix>.

As of TGT-038, that description is looked up first in C<$store> (via
C<get_message>, keyed on the original message's own C<chat_id>+
C<message_id>) - this is richer than Telegram's own payload for media/
voice, since it can be the downloaded file's C<local_path> or the actual
transcript rather than just the bare word C<photo>/C<document>/C<voice>.
Every successfully processed content line (text, transcribed voice, or
downloaded photo/document) is itself recorded into C<$store> via
C<record_message> immediately after being printed, so a later reply to it
can be looked up this way. Only when nothing is stored (a reply to a
message from before this feature existed, from a sender never allow-
listed at the time, or when C<$store> is not given at all) does the
suffix fall back to the original Telegram-payload-only behavior: a
sanitized/truncated (5000 chars, TGT-035) snippet of the original text,
or its media kind if the original had none.

=cut
