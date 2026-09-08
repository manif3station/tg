package Test::MandatoryDb;

use strict;
use warnings;
use Exporter 'import';
use File::Spec;

our @EXPORT_OK = qw(setup_mandatory_db_env);

=head1 NAME

Test::MandatoryDb - shared --db/-d/D2TG_DB mandatory env setup for cli/* subprocess tests

=head1 SYNOPSIS

    use FindBin qw($Bin);
    use File::Temp qw(tempdir);
    use lib "$Bin/lib";
    use Test::MandatoryDb qw(setup_mandatory_db_env);

    setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

=head1 DESCRIPTION

TGT-059 made C<--db>/C<-d>/C<D2TG_DB> mandatory for every C<d2 tg.*>
command, so every test file that spawns a C<cli/*> subprocess needs it
resolvable without a real Developer Dashboard install - via
C<t/lib/Developer/Dashboard.pm> and three env vars (C<D2TG_DB>,
C<D2TG_TEST_DB_ALIAS>, C<D2TG_TEST_DB_DIR>) plus C<PERL5LIB> pointing at
this C<t/lib/> directory. This four-line block was duplicated verbatim
across 5 test files (TGT-077, found via a scheduled improvement-hunt) -
extracted here, same precedent as C<t/lib/Fake/{Telegram,Store}.pm>
(TGT-018) and C<t/lib/Test/CaptureStdio.pm> (TGT-034).

=head2 setup_mandatory_db_env($Bin, $db_dir)

Sets C<PERL5LIB> (prepending C<$Bin/lib>), C<D2TG_DB>,
C<D2TG_TEST_DB_ALIAS> (both hardcoded to C<testalias>, matching every
caller's own usage), and C<D2TG_TEST_DB_DIR> (to the given C<$db_dir> -
the caller creates it, since some callers reuse the same directory for
other purposes, e.g. C<DEVELOPER_DASHBOARD_SKILL_ROOT> or building a
C<store.sqlite> path directly). Returns nothing; mutates C<%ENV> in
place, same as the inline code it replaces.

=cut

sub setup_mandatory_db_env {
    my ( $Bin, $db_dir ) = @_;

    $ENV{PERL5LIB} = join( ':', File::Spec->catdir( $Bin, 'lib' ), $ENV{PERL5LIB} // '' );
    $ENV{D2TG_DB}            = 'testalias';
    $ENV{D2TG_TEST_DB_ALIAS} = 'testalias';
    $ENV{D2TG_TEST_DB_DIR}   = $db_dir;

    return;
}

1;
