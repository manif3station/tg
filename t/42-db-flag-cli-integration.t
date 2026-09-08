use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

unless ( eval { require Developer::Dashboard; Developer::Dashboard->can('d2') } ) {
    plan skip_all => 'The real Developer::Dashboard (host d2 framework, not a CPAN dependency of this '
      . 'skill) with a working d2()/paths is not available in this environment (this test container has '
      . 'either no Developer::Dashboard at all, or an unrelated same-named CPAN package that does not '
      . 'define d2()). D2TG::Config::resolve_alias_dir\'s logic is fully covered via injected fake paths '
      . 'in t/40-db-alias-resolution.t; this file only adds CLI-process-level integration assurance where '
      . 'a real Developer Dashboard install is available.';
}

my $approve_cli = File::Spec->catfile( $Bin, '..', 'cli', 'approve.pl' );
my $reply_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'reply.pl' );

{
    local $ENV{D2TG_DB};
    my $out = `$approve_cli 123456 --db definitely-not-a-real-alias 2>/tmp/d2tg-approve-db-stderr.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-approve-db-stderr.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-approve-db-stderr.$$";

    is( $rc, 1, 'cli/approve --db <unknown alias> refuses to start (exit 1)' );
    like( $err, qr/Unknown --db.*definitely-not-a-real-alias/i, 'the STDERR message names the unknown alias' );
    like( $err, qr/d2 paths/i, 'the STDERR message points at d2 paths' );
    unlike( $out, qr/Approved/, 'cli/approve never claims success when the --db alias is unknown' );
}

{
    local $ENV{D2TG_DB} = 'also-not-real';
    my $out = `$approve_cli 123456 2>/tmp/d2tg-approve-envdb-stderr.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-approve-envdb-stderr.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-approve-envdb-stderr.$$";

    is( $rc, 1, 'D2TG_DB env var pointing at an unknown alias also refuses to start' );
    like( $err, qr/Unknown --db.*also-not-real/i, 'the STDERR message names the unknown alias from the env var' );
}

{
    local $ENV{D2TG_DB};
    my $out = `$reply_cli --db definitely-not-a-real-alias 123456 hello 2>/tmp/d2tg-reply-db-stderr.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-reply-db-stderr.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-reply-db-stderr.$$";

    is( $rc, 1, 'cli/reply --db <unknown alias> (leading position) refuses to start (exit 1)' );
    like( $err, qr/Unknown --db.*definitely-not-a-real-alias/i, 'the STDERR message names the unknown alias' );
    unlike( $out, qr/Replied to/, 'cli/reply never claims success when the --db alias is unknown' );
}

{
    local $ENV{D2TG_DB};
    local $ENV{TIRA_HOME};
    my $out = `$approve_cli 123456 2>/tmp/d2tg-approve-nodb-stderr.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-approve-nodb-stderr.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-approve-nodb-stderr.$$";

    is( $rc, 1, 'cli/approve with no --db/-d, no D2TG_DB, and no TIRA_HOME refuses to start (TGT-059)' );
    like( $err, qr/D2TG_DB.*--db.*-d/i, 'the STDERR message names the missing flag/env var' );
    unlike( $out, qr/Approved/, 'cli/approve never claims success with no --db anywhere' );
}

{
    local $ENV{D2TG_DB};
    local $ENV{TIRA_HOME};
    my $out = `$reply_cli 123456 hello 2>/tmp/d2tg-reply-nodb-stderr.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-reply-nodb-stderr.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-reply-nodb-stderr.$$";

    is( $rc, 1, 'cli/reply with no --db/-d, no D2TG_DB, and no TIRA_HOME refuses to start (TGT-059)' );
    like( $err, qr/D2TG_DB.*--db.*-d/i, 'the STDERR message names the missing flag/env var' );
    unlike( $out, qr/Replied to/, 'cli/reply never claims success with no --db anywhere' );
}

done_testing();
