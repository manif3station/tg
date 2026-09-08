use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

# TGT-072: a shared helper replacing 4 independent hand-rolled
# "shift a flag's value and validate it's not missing/empty/flag-like"
# implementations (TGT-068/069/070/071).

{
    my @args = ( 'foobar', 'rest1', 'rest2' );
    my $value = D2TG::Config::shift_flag_value( \@args, '--db/-d' );
    is( $value, 'foobar', 'shift_flag_value returns the shifted value' );
    is_deeply( \@args, [ 'rest1', 'rest2' ], 'shift_flag_value consumes only the one value it shifted' );
}

{
    my @args = ();
    eval { D2TG::Config::shift_flag_value( \@args, '--db/-d' ) };
    like( $@, qr/--db\/-d requires a value/, 'a bare trailing flag (nothing left in args) dies naming the flag label' );
}

{
    my @args = ('--since');
    eval { D2TG::Config::shift_flag_value( \@args, '--db/-d' ) };
    like( $@, qr/--db\/-d requires a value/, 'a flag immediately followed by another flag-like token dies instead of swallowing it' );
}

{
    my @args = ('');
    eval { D2TG::Config::shift_flag_value( \@args, '--since/--until' ) };
    like( $@, qr/--since\/--until requires a value/, 'an empty-string value dies naming the flag label given' );
}

{
    # Codex review during TGT-072: a negative Telegram group/supergroup
    # chat id (always negative, e.g. -1001234567890) must not be
    # rejected as flag-like - only a dash immediately followed by a
    # letter (an actual flag name) should be.
    my @args = ( '-1001234567890', 'rest' );
    my $value = D2TG::Config::shift_flag_value( \@args, '--chat_id' );
    is( $value, '-1001234567890', 'a negative numeric value (e.g. a Telegram group chat id) is accepted, not treated as flag-like' );
}

{
    my @args = ('-d');
    eval { D2TG::Config::shift_flag_value( \@args, '--foo' ) };
    like( $@, qr/--foo requires a value/, 'a short flag (dash + letter) immediately after is still correctly rejected as flag-like' );
}

done_testing();
