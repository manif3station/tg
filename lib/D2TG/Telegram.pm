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

sub send_message {
    my ( $self, $chat_id, $text, $limit, %opts ) = @_;

    my @results;
    if ( defined $opts{reply_to_message_id} ) {
        die "D2TG::Telegram sendMessage: reply_to_message_id must be numeric\n"
          unless $opts{reply_to_message_id} =~ /^\d+$/;
    }

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

    if ( defined $opts{reply_to_message_id} ) {
        die "D2TG::Telegram sendVoice: reply_to_message_id must be numeric\n"
          unless $opts{reply_to_message_id} =~ /^\d+$/;

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
syscall returns, this meant C<cli/poller>'s C<SIGINT>/C<SIGTERM> handlers
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
C<cli/poller> to thread a multi-bot pair's own receiving bot token
through to L<D2TG::Poller>'s C<REPLY WITH> template, so an operator
replying to a message from a non-default bot knows which C<--bot> to
pass to C<d2 tg.reply>.

=head2 get_me

Returns the bot's own user info.

=head2 get_updates(offset => $offset, timeout => $timeout)

Long-polls C<getUpdates>. Returns a two-element list: the array of update
hashes, and the offset to pass on the next call (one past the highest
C<update_id> seen, or the offset that was passed in if no updates arrived).

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
TGT-055 - matches C<send_voice>'s own validation below, so both send
methods enforce the same guarantee uniformly instead of one dying with a
clear local error and the other forwarding a bad value into Telegram's
API), and every chunk's C<sendMessage> call carries it, so the message
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
