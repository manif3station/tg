package D2TG::Telegram;

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON::PP qw(decode_json encode_json);
use File::Spec;
use D2TG::Config;

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
    my $res = D2TG::Config::_with_hard_timeout( $timeout, "D2TG::Telegram $method", sub { $self->{ua}->request($req) } );

    die "D2TG::Telegram $method: HTTP request failed (status @{[ $res->code ]} @{[ $res->message ]})\n"
      unless $res->is_success;

    my $data = eval { decode_json( $res->decoded_content ) };
    die "D2TG::Telegram $method: response was not valid JSON\n" unless $data;

    die "D2TG::Telegram $method failed: "
      . ( $data->{description} || 'unknown error' ) . "\n"
      unless $data->{ok};

    return $data->{result};
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

# TGT-290 (found via a user-requested comprehensive bug/improvement
# sweep): the previous formula ('D2TGBoundary' . int(rand(1e9)) . time)
# carried only ~30 bits of entropy. _send_file's own caption path already
# strips accidental boundary occurrences (TGT-162), but the uploaded
# file's raw bytes were never given the same protection, and send_voice's
# audio payload had no protection at all - a file whose raw bytes happen
# to contain the generated boundary string would corrupt the multipart
# request. 8 rounds of rand(65536) give 128 bits of real entropy (32 hex
# chars), making an accidental collision with real file content
# cryptographically improbable instead of merely improbable. Shared by
# send_voice and _send_file (send_photo/send_document) so the fix covers
# all 3 upload paths in one place.
sub _generate_boundary {
    return 'D2TGBoundary' . join( '', map { sprintf( '%04x', int( rand(65536) ) ) } 1 .. 8 ) . time;
}

sub _append_reply_to_message_id_field {
    my ( $body_ref, $boundary, $method, $reply_to_message_id ) = @_;

    # TGT-182 (found via a scheduled improvement hunt): the 5-line
    # "validate, then if defined append a multipart form-data
    # fragment" pattern appeared identically in send_voice and
    # _send_file - extracted here, matching this project's own
    # established "found it twice, extract it" convention
    # (TGT-167/170/171/172/177/181). $body_ref is a scalar ref, the
    # same by-reference approach TGT-181's _record_message_and_track_offset
    # already established, since the caller's own $body must keep
    # accumulating fragments after this call returns.
    _validate_reply_to_message_id( $method, $reply_to_message_id );
    if ( defined $reply_to_message_id ) {
        $$body_ref .= "--$boundary\r\n"
          . qq{Content-Disposition: form-data; name="reply_to_message_id"\r\n\r\n}
          . "$reply_to_message_id\r\n";
    }
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
    my $boundary = _generate_boundary();

    my $body = "--$boundary\r\n"
      . qq{Content-Disposition: form-data; name="chat_id"\r\n\r\n}
      . "$chat_id\r\n";

    _append_reply_to_message_id_field( \$body, $boundary, 'sendVoice', $opts{reply_to_message_id} );

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

    my $boundary = _generate_boundary();

    my $body = "--$boundary\r\n"
      . qq{Content-Disposition: form-data; name="chat_id"\r\n\r\n}
      . "$chat_id\r\n";

    _append_reply_to_message_id_field( \$body, $boundary, $method, $opts{reply_to_message_id} );

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
