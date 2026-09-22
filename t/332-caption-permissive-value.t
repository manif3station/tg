use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;
require D2TG::Config::Flags;

# TGT-332 (found via a live JOB-003 hourly bug hunt, 2026-09-22; Q-020
# answered by Michael 2026-09-22 - give --caption its own permissive
# validation, any non-empty value, since captions are free text unlike a
# token/id). D2TG::Config::Flags::shift_flag_value's own flag-shape guard
# (rejecting a value starting with a dash-letter pattern) is correct for
# --bot/--db/--reply-to-message-id, but wrong for --caption: a caption
# that legitimately starts with "--" (e.g. "--dry-run flag explained") is
# free text, not a token/id, and must never be misread as a missing flag
# value.

{
    my @args = ( '--hello world', 'rest' );
    my $value = D2TG::Config::Flags::shift_flag_value_free_text( \@args, '--caption' );
    is( $value, '--hello world', 'a value starting with a dash-letter pattern is accepted as-is, not misread as flag-like' );
    is_deeply( \@args, ['rest'], 'shift_flag_value_free_text consumes only the one value it shifted' );
}

{
    my @args = ();
    eval { D2TG::Config::Flags::shift_flag_value_free_text( \@args, '--caption' ) };
    like( $@, qr/--caption requires a value/, 'a bare trailing flag (nothing left in args) still dies naming the flag label' );
}

{
    my @args = ('');
    eval { D2TG::Config::Flags::shift_flag_value_free_text( \@args, '--caption' ) };
    like( $@, qr/--caption requires a value/, 'an empty-string value still dies naming the flag label - free text does not mean "anything at all"' );
}

{
    my @args = ('-1001234567890');
    my $value = D2TG::Config::Flags::shift_flag_value_free_text( \@args, '--caption' );
    is( $value, '-1001234567890', 'a value that looks like a negative number is accepted, same as the strict helper already allowed' );
}

# Regression guard: the strict helper (used by --bot/--db/--reply-to-message-id)
# is untouched by this change - it must still reject a flag-shaped value.
{
    my @args = ('--since');
    eval { D2TG::Config::Flags::shift_flag_value( \@args, '--db/-d' ) };
    like( $@, qr/--db\/-d requires a value/, 'the strict shift_flag_value helper is unchanged - still rejects a flag-like value' );
}

done_testing();
