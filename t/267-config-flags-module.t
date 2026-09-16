use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-267: shift_flag_value/extract_db_flag/extract_db_flag_or_die/
# bot_groups were an organizational mismatch in D2TG::Config.pm - CLI
# flag-parsing is a distinct concern from the module's own
# env-reading/version/error-classification concerns. Extracted into
# D2TG::Config::Flags, mirroring D2TG::Reply::Args/D2TG::Config::Paths's
# own precedent. This proves ownership; the deep behavioral coverage
# for all four functions already exists across many test files -
# updated in this same ticket to call the new location.
require D2TG::Config;
require D2TG::Config::Flags;

can_ok( 'D2TG::Config::Flags', 'shift_flag_value' );
can_ok( 'D2TG::Config::Flags', 'extract_db_flag' );
can_ok( 'D2TG::Config::Flags', 'extract_db_flag_or_die' );
can_ok( 'D2TG::Config::Flags', 'bot_groups' );

ok( !D2TG::Config->can('shift_flag_value'), 'D2TG::Config no longer defines shift_flag_value' );
ok( !D2TG::Config->can('extract_db_flag'), 'D2TG::Config no longer defines extract_db_flag' );
ok( !D2TG::Config->can('extract_db_flag_or_die'), 'D2TG::Config no longer defines extract_db_flag_or_die' );
ok( !D2TG::Config->can('bot_groups'), 'D2TG::Config no longer defines bot_groups' );

# D2TG::Config's own genuine concern (env-reading, version, error
# classification) is untouched.
can_ok( 'D2TG::Config', 'token' );
can_ok( 'D2TG::Config', 'chat_id' );
can_ok( 'D2TG::Config', 'skill_version' );
can_ok( 'D2TG::Config', 'is_transient_error' );

done_testing();
