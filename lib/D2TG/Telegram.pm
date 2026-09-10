package D2TG::Telegram;

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON::PP qw(decode_json encode_json);
use File::Spec;

use constant DEFAULT_HARD_TIMEOUT => 50;
use constant DEFAULT_LONG_POLL_MARGIN => 20;

sub new {
    my ( $class, %args ) = @_;

    my $token = $args{token} or die "D2TG::Telegram->new requires a token\n";

    return bless {
        token => $token,
        api   => "https://api.telegram.org/bot$token",
        ua    => $args{ua} || LWP::UserAgent->new( timeout => DEFAULT_HARD_TIMEOUT ),
    }, $class;
}

sub token {
    my ($self) = @_;
    return $self->{token};
}

sub _call {
    my ( $self, $method, $params, %opts ) = @_;

    my $headers = $opts{headers} || { 'Content-Type' => 'application/json' };
    my $content = defined $opts{raw_content} ? $opts{raw_content} : encode_json( $params || {} );

    my $req = HTTP::Request->new( POST => "$self->{api}/$method" );
    $req->header( %$headers );
    $req->content($content);

    my $timeout = eval { $self->{ua}->timeout } || DEFAULT_HARD_TIMEOUT;
    my $res = _with_hard_timeout( $timeout, $method, sub { $self->{ua}->request($req) } );

    die "D2TG::Telegram $method: HTTP request failed (status @{[ $res->code ]} @{[ $res->message ]})\n"
      unless $res->is_success;

    my $data = eval { decode_json( $res->decoded_content ) };
    die "D2TG::Telegram $method: response was not valid JSON\n" unless $data;

    die "D2TG::Telegram $method failed: "
      . ( $data->{description} || 'unknown error' ) . "\n"
      unless $data->{ok};

    return $data->{result};
}

sub _with_hard_timeout {
    my ( $seconds, $method, $coderef ) = @_;

    my $result;
    eval {
        local $SIG{ALRM} = sub { die "D2TG::Telegram $method: request timed out after ${seconds}s\n" };
        alarm($seconds);
        $result = $coderef->();
        alarm(0);
    };
    my $error = $@;
    alarm(0);
    die $error if $error;

    return $result;
}

sub _utf16_units {
    my ($codepoint) = @_;
    return $codepoint > 0xFFFF ? 2 : 1;
}

sub split_text_utf16 {
    my ( $text, $limit ) = @_;
    $limit //= 4000;

    my @chunks;
    my $current = '';
    my $units   = 0;

    for my $ch ( split //, $text ) {
        my $cost = _utf16_units( ord($ch) );

        if ( $units + $cost > $limit && length $current ) {
            push @chunks, $current;
            $current = '';
            $units   = 0;
        }

        $current .= $ch;
        $units   += $cost;
    }

    push @chunks, $current if length $current;

    return @chunks;
}

sub get_me {
    my ($self) = @_;
    return $self->_call( 'getMe', {} );
}

sub get_updates {
    my ( $self, %args ) = @_;

    my $params = { timeout => $args{timeout} // ( DEFAULT_HARD_TIMEOUT - DEFAULT_LONG_POLL_MARGIN ) };
    $params->{offset} = $args{offset} if defined $args{offset};

    # TGT-143 (live Telegram question, msg #176): reactions
    # (message_reaction updates) are opt-in per the Bot API - never
    # delivered unless explicitly listed in allowed_updates. Telegram's
    # own docs warn that once allowed_updates is specified at all, only
    # the listed types are delivered - so every update type this
    # poller already relies on must be listed explicitly here too, not
    # just the new reaction type, or this would silently break existing
    # inbound message handling. A Codex review raised whether narrowing
    # from Telegram's own default (every type except chat_member, when
    # allowed_updates is omitted entirely) to just these two could
    # silently drop something - confirmed via a full grep of this
    # project's own code that edited_message/callback_query/
    # channel_post are never read anywhere, so nothing currently
    # observable narrows; deliberately scoped to the ticket's own
    # explicit solution text ("message, at minimum") rather than
    # expanding beyond what was asked.
    #
    # TGT-169 (live Telegram question, msg #246, Michael): edited_message
    # added. Codex review correction: edited_message is NOT itself
    # opt-in the way message_reaction is - Telegram's baseline default
    # (before this project ever specified allowed_updates at all)
    # already included it, only chat_member/message_reaction/
    # message_reaction_count were excluded from that baseline. It
    # stopped reaching this project the moment TGT-143 first narrowed
    # allowed_updates to [message, message_reaction] - this client's
    # own explicit list, not Telegram's baseline, is what was excluding
    # it. That baseline is historical, not a live fallback: per
    # Telegram's own docs, getUpdates retains whichever allowed_updates
    # list a bot last set rather than reverting to the baseline default
    # if a later call omits the parameter, so omitting it now would not
    # restore edited_message - it must be listed explicitly, as done
    # here. callback_query/channel_post remain deliberately excluded -
    # still never read anywhere in this project.
    $params->{allowed_updates} = $args{allowed_updates}
      // [qw(message edited_message message_reaction)];

    my $updates = $self->_call( 'getUpdates', $params );

    my $next_offset = $args{offset};
    for my $update (@$updates) {
        my $candidate = $update->{update_id} + 1;
        $next_offset = $candidate
          if !defined $next_offset || $candidate > $next_offset;
    }

    return ( $updates, $next_offset );
}

sub get_file {
    my ( $self, $file_id ) = @_;

    my $result = $self->_call( 'getFile', { file_id => $file_id } );
    return $result->{file_path};
}

sub file_download_url {
    my ( $self, $file_path ) = @_;
    return "https://api.telegram.org/file/bot$self->{token}/$file_path";
}

# TGT-171: extracted after this exact validation block was found
# triplicated (send_message, send_voice, _send_file) - matches the
# established shift_flag_value (TGT-072) / _classify_store_error
# (TGT-167) / _format_forwarded_sender (TGT-170) precedent for this
# shape of duplication.
sub _validate_reply_to_message_id {
    my ( $method, $reply_to_message_id ) = @_;

    return unless defined $reply_to_message_id;
    die "D2TG::Telegram $method: reply_to_message_id must be numeric\n"
      unless $reply_to_message_id =~ /^\d+$/;
    return;
}

sub send_message {
    my ( $self, $chat_id, $text, $limit, %opts ) = @_;

    my @results;
    _validate_reply_to_message_id( 'sendMessage', $opts{reply_to_message_id} );

    for my $chunk ( split_text_utf16( $text, $limit ) ) {
        my $payload = { chat_id => $chat_id, text => $chunk };
        $payload->{reply_to_message_id} = $opts{reply_to_message_id}
          if defined $opts{reply_to_message_id};
        push @results, $self->_call( 'sendMessage', $payload );
    }
    return \@results;
}

sub send_voice {
    my ( $self, $chat_id, $file_path, %opts ) = @_;

    open my $fh, '<:raw', $file_path
      or die "D2TG::Telegram sendVoice: cannot read $file_path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;

    my ( undef, undef, $filename ) = File::Spec->splitpath($file_path);
    my $boundary = 'D2TGBoundary' . int( rand(1e9) ) . time;

    my $body = "--$boundary\r\n"
      . qq{Content-Disposition: form-data; name="chat_id"\r\n\r\n}
      . "$chat_id\r\n";

    _validate_reply_to_message_id( 'sendVoice', $opts{reply_to_message_id} );
    if ( defined $opts{reply_to_message_id} ) {
        $body .= "--$boundary\r\n"
          . qq{Content-Disposition: form-data; name="reply_to_message_id"\r\n\r\n}
          . "$opts{reply_to_message_id}\r\n";
    }

    $body .= "--$boundary\r\n"
      . qq{Content-Disposition: form-data; name="voice"; filename="$filename"\r\n}
      . "Content-Type: audio/ogg\r\n\r\n"
      . $data . "\r\n"
      . "--$boundary--\r\n";

    return $self->_call(
        'sendVoice', undef,
        headers     => { 'Content-Type' => "multipart/form-data; boundary=$boundary" },
        raw_content => $body,
    );
}

sub send_photo {
    my ( $self, $chat_id, $file_path, %opts ) = @_;
    return $self->_send_file( 'sendPhoto', 'photo', $chat_id, $file_path, %opts );
}

sub send_document {
    my ( $self, $chat_id, $file_path, %opts ) = @_;
    return $self->_send_file( 'sendDocument', 'document', $chat_id, $file_path, %opts );
}

sub _send_file {
    my ( $self, $method, $field_name, $chat_id, $file_path, %opts ) = @_;

    open my $fh, '<:raw', $file_path
      or die "D2TG::Telegram $method: cannot read $file_path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;

    my ( undef, undef, $filename ) = File::Spec->splitpath($file_path);

    # TGT-125 (found via a scheduled hourly bug-hunt): $filename is
    # inserted directly into a quoted Content-Disposition attribute
    # below, and cli/tg.send's own $file_path is a user-supplied local
    # path - a literal double-quote in its basename would otherwise
    # prematurely close that attribute, corrupting the header line
    # (Telegram then sees a malformed multipart request). Escape
    # backslashes first, then quotes, matching the standard MIME
    # quoted-string escaping convention (RFC 7578, the current
    # multipart/form-data spec - backslash-escape both characters).
    # send_voice's own equivalent filename (below, a
    # separate code path) is deliberately not touched here - it always
    # comes from D2TG::TTS::synthesize's own File::Temp-generated name,
    # never user-controlled, so it's out of this ticket's scope.
    #
    # Codex review finding (real, high-severity): on Unix a filename can
    # legally contain CR/LF (and other control characters) - left in
    # place, those would inject additional raw header lines into this
    # multipart request regardless of the quote/backslash escaping
    # below, since CR/LF is what actually terminates a header line
    # here. Strip C0 control characters (0x00-0x1F) plus DEL (0x7F,
    # per a Codex review's own strict quoted-string hygiene suggestion -
    # DEL itself cannot inject a header, just extra hardening) entirely
    # first -
    # the file is still sent correctly, just with a sanitized displayed
    # filename, rather than refusing the whole send over a cosmetic
    # detail Telegram never surfaces to the recipient anyway.
    ( my $safe_filename = $filename ) =~ s/[\x00-\x1F\x7F]//g;
    ( my $escaped_filename = $safe_filename ) =~ s/([\\"])/\\$1/g;

    my $boundary = 'D2TGBoundary' . int( rand(1e9) ) . time;

    my $body = "--$boundary\r\n"
      . qq{Content-Disposition: form-data; name="chat_id"\r\n\r\n}
      . "$chat_id\r\n";

    _validate_reply_to_message_id( $method, $opts{reply_to_message_id} );
    if ( defined $opts{reply_to_message_id} ) {
        $body .= "--$boundary\r\n"
          . qq{Content-Disposition: form-data; name="reply_to_message_id"\r\n\r\n}
          . "$opts{reply_to_message_id}\r\n";
    }

    if ( defined $opts{caption} && length $opts{caption} ) {

        # TGT-162 (found via a scheduled hourly bug-hunt): caption sits
        # in body content, not a quoted header attribute like $filename
        # above, so it needs no quote/backslash escaping or control-
        # character stripping - CR/LF here is legitimate caption text,
        # not a header-injection vector. What it does share with
        # $filename is the same trust boundary (a user-supplied
        # cli/send.pl argument) and a real risk of its own: if the
        # caption happens to embed the literal $boundary string this
        # call generated in real delimiter syntax (preceded by its own
        # \r\n--), it would prematurely terminate the multipart body,
        # letting trailing bytes be reinterpreted as new form fields.
        # The bare boundary string alone is not itself a delimiter, but
        # stripping every occurrence of it, delimiter-shaped or not, is
        # the conservative fix - it can never leave a valid delimiter
        # behind for the caption to complete accidentally or otherwise.
        # (The uploaded file's own raw bytes could in principle collide
        # with the boundary the same way - a separate, pre-existing,
        # unaddressed risk out of this ticket's scope.)
        ( my $safe_caption = $opts{caption} ) =~ s/\Q$boundary\E//g;

        $body .= "--$boundary\r\n"
          . qq{Content-Disposition: form-data; name="caption"\r\n\r\n}
          . "$safe_caption\r\n";
    }

    $body .= "--$boundary\r\n"
      . qq{Content-Disposition: form-data; name="$field_name"; filename="$escaped_filename"\r\n}
      . "Content-Type: application/octet-stream\r\n\r\n"
      . $data . "\r\n"
      . "--$boundary--\r\n";

    return $self->_call(
        $method, undef,
        headers     => { 'Content-Type' => "multipart/form-data; boundary=$boundary" },
        raw_content => $body,
    );
}

1;

=head1 NAME

D2TG::Telegram - minimal Telegram Bot API client

=head1 SYNOPSIS

    my $tg = D2TG::Telegram->new( token => $token );
    my $me = $tg->get_me;
    my ( $updates, $next_offset ) = $tg->get_updates( offset => $offset );
    my $file_path = $tg->get_file($file_id);

=head1 DESCRIPTION

Raw HTTP client against the Telegram Bot API - no SDK dependency, matching
the C<~/skills/tg> blueprint's own "no heavy SDK" principle. Uses
L<LWP::UserAgent> by default (TGT-028); pass C<ua> to the constructor to
inject a different (or mock) client for testing.

Every C<_call> is additionally wrapped in a hard, C<SIGALRM>-based
timeout (TGT-044, a real production incident: the underlying C<ua>'s own
C<timeout> setting - relied on since TGT-035 - was observed to NOT bound
a request stuck in the initial TCP C<connect()> phase; the live poller
process hung indefinitely with its socket wedged in C<SYN-SENT>, and
even C<SIGTERM> could not stop it, since Perl only delivers a signal
once the blocking syscall it's inside of returns). C<alarm()>/C<SIGALRM>
reliably interrupts any blocking syscall in Perl, unlike trusting a
library's own internal timeout implementation to cover every phase. The
bound used is the C<ua>'s own C<timeout> value if it exposes one (a real
L<LWP::UserAgent> does), otherwise C<DEFAULT_HARD_TIMEOUT> (50s (TGT-066),
matching the C<ua>'s own default).

=head1 METHODS

=head2 new(token => $token, ua => $optional_client)

The default C<ua> is an L<LWP::UserAgent> with an explicit C<timeout =E<gt>
DEFAULT_HARD_TIMEOUT> (originally 35, TGT-035, a real production incident:
LWP's own default is 180s, so a single C<get_updates> long-poll call -
default C<timeout =E<gt> 30> - could block for up to 180s with no explicit
bound. Since Perl defers signal handling until the current blocking
syscall returns, this meant C<cli/poller.pl>'s C<SIGINT>/C<SIGTERM> handlers
could be delayed by up to 180s even after TGT-031's transcription-timeout
fix, which only bounded a different blocking call). Widened to 50s
(TGT-066, another real production incident: a 35s bound left only a 5s
margin over C<get_updates>' own 30s server-side long-poll wait, so a
perfectly legitimate, successful response taking slightly longer than
35s total under normal network/TLS/latency overhead was mistaken for a
genuinely stuck connection - the 15s margin now bounds both shutdown
delay and new-message latency to a known, short maximum without
false-positive timeouts on ordinary long-poll responses.

=head2 token

Returns the token this object was constructed with (TGT-057) - used by
C<cli/poller.pl> to thread a multi-bot pair's own receiving bot token
through to L<D2TG::Poller>'s C<REPLY WITH> template, so an operator
replying to a message from a non-default bot knows which C<--bot> to
pass to C<d2 tg.reply>.

=head2 get_me

Returns the bot's own user info.

=head2 get_updates(offset => $offset, timeout => $timeout, allowed_updates => \@types)

Long-polls C<getUpdates>. Returns a two-element list: the array of update
hashes, and the offset to pass on the next call (one past the highest
C<update_id> seen, or the offset that was passed in if no updates arrived).

C<allowed_updates> defaults to C<[qw(message edited_message message_reaction)]>
(C<message_reaction> - TGT-143; C<edited_message> - TGT-169, both live
Telegram questions). C<message_reaction> is genuinely opt-in - excluded
from Telegram's own baseline default set even when C<allowed_updates>
is omitted on a bot's very first C<getUpdates> call ever.
C<edited_message> is not - that same baseline default already includes
it, and it only stopped reaching this project the moment TGT-143 first
narrowed C<allowed_updates> to a fixed list. This is a historical fact
about that baseline, not a live fallback: per Telegram's own docs,
C<getUpdates> retains whatever C<allowed_updates> a bot last explicitly
set rather than reverting to the baseline default on a later call that
omits the parameter, so simply omitting it now (after TGT-143's own
narrowing already took effect) would not restore C<edited_message> -
it has to be listed explicitly, which is what this default now does.
Telegram's own docs warn that specifying C<allowed_updates> at
all restricts delivery to I<only> the listed types, so this default
deliberately preserves every update type this project currently relies
on (C<message>) alongside each newly-added one, rather than adding a
type in isolation and silently narrowing everything else. A caller may
pass its own C<allowed_updates> to override this default entirely.

C<timeout> defaults to C<DEFAULT_HARD_TIMEOUT - DEFAULT_LONG_POLL_MARGIN>
(50 - 20 = 30, TGT-067) rather than a bare literal - this keeps the
margin TGT-066 established (the hard timeout must leave real headroom
over the long-poll wait, or a legitimate slow-but-successful response
gets mistaken for a hung connection) enforced as a code-level invariant
instead of two numbers that merely happen to agree. No current caller
passes an explicit C<timeout>, so this is unchanged behavior.

=head2 get_file($file_id)

Returns the C<file_path> for a given C<file_id>, for use with Telegram's
file-download endpoint.

=head2 file_download_url($file_path)

Builds the full download URL for a C<file_path> previously returned by
C<get_file> (Telegram's file-download endpoint is separate from, and
embeds the same bot token as, the regular Bot API endpoint).

=head2 send_message($chat_id, $text, $limit = 4000, reply_to_message_id => $id)

Sends C<$text> to C<$chat_id> via C<sendMessage>, splitting it across
multiple calls if it exceeds C<$limit> UTF-16 code units (Telegram's own
hard cap is 4096; this defaults to 4000 to leave headroom). Returns an
arrayref of the raw Telegram result for each call made. C<reply_to_message_id>
(TGT-040) is optional; when given, it must be numeric (dies otherwise,
TGT-055 - via the shared L</_validate_reply_to_message_id> helper
(TGT-171), also used by C<send_voice> below, so both send methods
enforce the same guarantee uniformly instead of one dying with a clear
local error and the other forwarding a bad value into Telegram's API),
and every chunk's C<sendMessage> call carries it, so the message
threads natively under the original message in Telegram's UI. Omitting
it is unchanged from before this ticket.

=head2 send_voice($chat_id, $file_path, reply_to_message_id => $id)

Sends the audio file at C<$file_path> to C<$chat_id> via C<sendVoice>,
built as a raw C<multipart/form-data> request body (no external multipart
dependency). Dies if C<$file_path> cannot be read. C<reply_to_message_id>
(TGT-040) is optional; when given, it must be numeric (dies otherwise -
the multipart body here is hand-built raw string concatenation, unlike
C<send_message>'s JSON-encoded payload, so this guards against a
CRLF/boundary-containing value injecting extra multipart fields) and an
extra C<reply_to_message_id> field is added to the body before the
C<voice> field.

=head2 send_photo($chat_id, $file_path, caption => $text, reply_to_message_id => $id)

=head2 send_document($chat_id, $file_path, caption => $text, reply_to_message_id => $id)

TGT-103: push a local file to C<$chat_id> as a Telegram photo or
document, via the shared L</_send_file> helper (same raw hand-built
multipart approach as L</send_voice>). C<caption>/C<reply_to_message_id>
are optional.

=head2 _send_file($method, $field_name, $chat_id, $file_path, %opts)

Internal helper backing L</send_photo>/L</send_document>. TGT-125
(found via a scheduled bug-hunt): the local file's basename is escaped
and sanitized before being inserted into the multipart
C<Content-Disposition> header's C<filename="...">> attribute - a
literal double-quote in it previously prematurely closed that quoted
attribute, corrupting the header line into a malformed multipart
request; a literal CR/LF (legal in a Unix filename) could have injected
an additional raw header line into the request entirely, the same
class of hand-built-multipart injection risk L</send_voice>'s own
C<reply_to_message_id> validation above already guards against for a
different field. C0 control characters and DEL (C<0x00>-C<0x1F>,
C<0x7F>) are stripped first, then backslashes and quotes are escaped
(C<\\> and C<\">, matching the standard MIME quoted-string escaping
convention, RFC 7578) - the file still uploads correctly either way, only the
displayed filename is sanitized. C<send_voice>'s own equivalent
filename (always a C<D2TG::TTS::synthesize>-generated C<File::Temp>
name, never user-controlled) is deliberately not touched by this fix.

TGT-162 (found via a scheduled hourly bug-hunt): C<caption> shares the
same trust boundary as C<filename> above (a user-supplied
C<cli/send.pl> argument) but sits in plain body content rather than a
quoted header attribute, so none of C<filename>'s escaping applies -
CR/LF in a caption is legitimate text, not a header-injection vector.
Its one real risk is narrower: the multipart boundary itself
(C<'D2TGBoundary' . int(rand(1e9)) . time>, regenerated per call) is
what separates form-data parts - a real delimiter is C<\r\n--$boundary>
with valid trailing framing, not the bare value alone - and a caption
embedding that string in delimiter-shaped syntax could prematurely
terminate the body, letting trailing bytes be reinterpreted as new form
fields. Any occurrence of the literal C<$boundary> string, delimiter-
shaped or not, is conservatively stripped from the caption before
insertion. Caption is not the only untrusted multipart body content -
the uploaded file's own raw bytes could in principle collide with the
boundary the same way - but that pre-existing risk is unaddressed here
and out of this ticket's scope, relying (as it always has) on the
per-call boundary being unpredictable.

=head2 _with_hard_timeout($seconds, $method, \&coderef)

Internal helper (TGT-044): runs C<&coderef> under C<alarm($seconds)>, so
a C<SIGALRM> forcibly interrupts it - including a blocking syscall like
C<connect()> - if it hasn't returned within C<$seconds>. On timeout,
dies with C<< D2TG::Telegram <method>: request timed out after
<seconds>s >>. C<alarm(0)> is always called before returning or
re-throwing, whether the call succeeded, failed, or timed out, so no
alarm is ever left pending.

=head2 split_text_utf16($text, $limit = 4000)

Splits C<$text> into chunks of at most C<$limit> UTF-16 code units each,
without ever splitting a single codepoint (so a supplementary-plane
character, which encodes as a UTF-16 surrogate pair, is never divided
across two chunks). Returns the list of chunks; joining them reproduces
the original text exactly.

=cut
