package D2TG::Config;

use strict;
use warnings;

sub token   { return $ENV{D2TG_TOKEN}; }
sub chat_id { return $ENV{D2TG_CHAT_ID}; }

sub require_chat_id_or_warn {
    my $chat_id = chat_id();

    if ( !defined $chat_id || $chat_id eq '' ) {
        warn "D2TG_CHAT_ID is not set - refusing to start the poller.\n";
        return 0;
    }

    return 1;
}

1;
