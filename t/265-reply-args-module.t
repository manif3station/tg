use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-265: extract_bot_flag/extract_bot_flag_or_die/parse_cli_args
# were an organizational mismatch in D2TG::Reply.pm - CLI argv-parsing
# is a distinct concern from send_reply/resend_voice's network/
# store-write concern, and extract_bot_flag_or_die is already called
# by 8 cli/*.pl scripts beyond reply.pl, so it isn't really
# reply-specific logic either. Extracted into D2TG::Reply::Args,
# mirroring D2TG::Store::RetryQueue/D2TG::Config::Paths's own
# precedent. This proves ownership; the deep behavioral coverage for
# all three functions already exists in t/34/51/61/62/210/227/231/236/
# 240/264 - updated in this same ticket to call the new location.
require D2TG::Reply;
require D2TG::Reply::Args;

can_ok( 'D2TG::Reply::Args', 'extract_bot_flag' );
can_ok( 'D2TG::Reply::Args', 'extract_bot_flag_or_die' );
can_ok( 'D2TG::Reply::Args', 'parse_cli_args' );

ok( !D2TG::Reply->can('extract_bot_flag'), 'D2TG::Reply no longer defines extract_bot_flag' );
ok( !D2TG::Reply->can('extract_bot_flag_or_die'), 'D2TG::Reply no longer defines extract_bot_flag_or_die' );
ok( !D2TG::Reply->can('parse_cli_args'), 'D2TG::Reply no longer defines parse_cli_args' );

# D2TG::Reply's own genuine concern (send/voice/store) is untouched.
can_ok( 'D2TG::Reply', 'send_reply' );
can_ok( 'D2TG::Reply', 'resend_voice' );
can_ok( 'D2TG::Reply', 'format_send_error' );

done_testing();
