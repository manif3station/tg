use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

require D2TG::Store;

# TGT-215 (found via a scheduled JOB-004 improvement hunt): TGT-098 gave
# the pending table a composite PRIMARY KEY (chat_id, bot_key)
# specifically so the same chat_id can be legitimately pending under
# more than one configured bot. Every sibling accessor on this table
# (is_allowed/add_pending/approve) was updated to take/scope by
# bot_key - pending_chat_ids alone was missed: it ran a bare
# 'SELECT chat_id FROM pending' with no bot_key filter and no DISTINCT,
# so a chat_id pending under two bots produced two identical,
# unlabeled rows.

sub fresh_db_path {
    my ( $fh, $path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $path;
    return $path;
}

{
    my $db    = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    $store->add_pending( 111, 'tokenA' );
    $store->add_pending( 111, 'tokenB' );

    my @unscoped = $store->pending_chat_ids;
    is( scalar @unscoped, 1, 'a chat_id pending under two different bot_keys appears exactly once unscoped (DISTINCT)' );
    is( $unscoped[0], 111, 'the correct chat_id is returned' );

    my @scoped_a = $store->pending_chat_ids( bot_key => 'tokenA' );
    is_deeply( \@scoped_a, [111], 'bot_key => tokenA scoping still returns the pending chat_id' );

    my @scoped_c = $store->pending_chat_ids( bot_key => 'tokenC' );
    is_deeply( \@scoped_c, [], 'a bot_key with no pending entries returns nothing' );
}

# Regression: single-bot mode (no bot_key ever passed anywhere) is
# completely unaffected - matching t/05-access-control.t's own
# established assertions.
{
    my $db    = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    $store->add_pending(111);
    is( scalar $store->pending_chat_ids, 1, 'single-bot mode: the pending chat id is recorded' );
    is( ( $store->pending_chat_ids )[0], 111, 'single-bot mode: the recorded pending id matches' );
}

# Regression: distinct chat_ids under distinct bot_keys are all listed,
# not collapsed.
{
    my $db    = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    $store->add_pending( 111, 'tokenA' );
    $store->add_pending( 222, 'tokenB' );

    my @unscoped = sort { $a <=> $b } $store->pending_chat_ids;
    is_deeply( \@unscoped, [ 111, 222 ], 'genuinely distinct chat_ids under distinct bot_keys are both listed' );
}

done_testing();
