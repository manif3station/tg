package D2TG::Poller::Format;

use strict;
use warnings;
use POSIX qw(strftime);
use D2TG::Config;

# TGT-259: extracted out of D2TG::Poller.pm (which had grown to 1604
# lines) - these 13 functions are pure stdout-line formatting/
# presentation helpers with no poll-loop state, called only to build
# the strings D2TG::Poller::run_once prints. D2TG::Poller keeps thin
# forwarding subs with the same (underscore-prefixed) names for every
# existing internal call site and the one confirmed external caller
# (t/226-bot-flag-helper-extracted.t calls D2TG::Poller::_bot_flag
# directly) - no behavior change, just a smaller Poller.pm.

sub display_name {
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

sub reply_context_suffix {
    my ( $message, $store, $chat_id, $bot_token ) = @_;

    my $original = $message->{reply_to_message};
    return '' unless $original;

    my $original_sender = display_name( $chat_id, $original->{from}{username} );

    # TGT-142: the replied-to message can itself be a forward - same
    # gap, same fix, so a reply-context line never attributes a
    # forwarded message to its forwarder either.
    $original_sender = format_forwarded_sender( $original_sender, $original->{forward_origin} );

    my $original_message_id = $original->{message_id};
    my $id_note = defined $original_message_id ? " [msg #$original_message_id]" : '';

    my $what = stored_summary( $store, $chat_id, $original_message_id, $bot_token );

    unless ( defined $what ) {
        my $original_text = $original->{text};
        if ( defined $original_text && length $original_text ) {
            my $safe = sanitize_for_stdout($original_text);
            $safe = substr( $safe, 0, 5000 ) . '...' if length $safe > 5000;
            $what = $safe;
        }
        else {
            $what = media_kind($original) // 'message';
        }
    }

    return qq{ (replying to $original_sender$id_note: $what)};
}

sub stored_summary {
    my ( $store, $chat_id, $message_id, $bot_token ) = @_;

    return undef unless $store && defined $chat_id && defined $message_id;

    my $stored = $store->get_message( $chat_id, $message_id, bot_key => $bot_token );

    return $stored ? $stored->{summary} : undef;
}

sub timestamp_prefix {
    my ($message) = @_;

    my $epoch = $message->{date} // time;

    return '[' . strftime( '%Y-%m-%d %H:%M:%S', localtime($epoch) ) . ']';
}

sub sanitize_for_stdout {
    my ($text) = @_;

    ( my $safe = $text ) =~ s/\r?\n/\\n/g;
    $safe =~ s/[\x00-\x08\x0B-\x1F\x7F]//g;

    return $safe;
}

sub bot_flag {
    my ($bot_token) = @_;

    # TGT-086: never print the real token here - both this helper's
    # callers reach the target project's tira.policy.bridge as a
    # monitor-output event (visible to anyone who can read that
    # board), and the token is a real credential (whoever has it can
    # send/receive as that bot). Masked the same way
    # D2TG::Config::masked_token already masks the startup line
    # (TGT-045).
    return defined $bot_token
      ? ' --bot ' . D2TG::Config::masked_token($bot_token)
      : '';
}

sub print_reply_template {
    my ( $chat_id, $message_id, $bot_token ) = @_;

    # TGT-227: --bot must be printed BEFORE $chat_id, not after - see
    # D2TG::Poller's own forwarder POD for the full incident history.
    my $bot_flag   = bot_flag($bot_token);
    my $reply_flag = defined $message_id ? " --reply-to-message-id $message_id" : '';
    print qq{REPLY WITH: d2 tg.reply$bot_flag $chat_id "..."$reply_flag\n};
    return;
}

sub print_attachment_template {
    my ( $chat_id, $message_id ) = @_;

    # TGT-133: never print the real local filesystem path here.
    print "GET ATTACHMENT WITH: d2 tg.attachment $chat_id $message_id\n";
    return;
}

sub reaction_key {
    my ($reaction) = @_;

    my $type = $reaction->{type} // '';
    return "emoji:@{[ $reaction->{emoji} // '' ]}"                 if $type eq 'emoji';
    return "custom_emoji:@{[ $reaction->{custom_emoji_id} // '' ]}" if $type eq 'custom_emoji';
    return 'paid'                                                  if $type eq 'paid';
    return "unknown:$type";
}

sub reaction_label {
    my ($reaction) = @_;

    my $type = $reaction->{type} // '';
    return $reaction->{emoji}                if $type eq 'emoji' && defined $reaction->{emoji};
    return 'a custom emoji'                  if $type eq 'custom_emoji';
    return 'a paid reaction'                 if $type eq 'paid';
    return 'an unrecognized reaction type';
}

sub forward_origin_name {
    my ($origin) = @_;

    return undef unless $origin;

    my $type = $origin->{type} // '';

    if ( $type eq 'user' ) {
        my $u = $origin->{sender_user} // {};

        # TGT-142, Michael's own instruction: use the origin's NAME,
        # never the numeric user id - username first (matching
        # display_name's own convention), first_name as fallback.
        return $u->{username} // $u->{first_name} // 'unknown';
    }
    elsif ( $type eq 'hidden_user' ) {

        # MessageOriginHiddenUser: the original sender's privacy
        # settings withhold their real identity from bots entirely -
        # Telegram supplies only a display name string, no id.
        return $origin->{sender_user_name} // 'unknown (privacy-restricted)';
    }
    elsif ( $type eq 'chat' ) {
        my $c = $origin->{sender_chat} // {};
        return $c->{title} // $c->{username} // 'a chat';
    }
    elsif ( $type eq 'channel' ) {
        my $c = $origin->{chat} // {};
        return $c->{title} // $c->{username} // 'a channel';
    }

    return undef;
}

sub format_forwarded_sender {
    my ( $sender, $forward_origin ) = @_;

    my $origin_name = forward_origin_name($forward_origin);
    return $sender unless defined $origin_name;

    return sanitize_for_stdout($origin_name) . " (forwarded by $sender)";
}

sub media_kind {
    my ($message) = @_;

    return 'photo'    if $message->{photo};
    return 'document' if $message->{document};
    return 'voice'    if $message->{voice};

    # TGT-161: a video message had neither $message->{text}> nor a
    # recognized media kind, so it silently failed run_once's own
    # guard - video_note/audio/animation/sticker are the same failure
    # class but deliberately out of scope here.
    return 'video' if $message->{video};

    return undef;
}

1;

