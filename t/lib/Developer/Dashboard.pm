package Developer::Dashboard;

use strict;
use warnings;

sub d2 {
    return bless {}, 'Developer::Dashboard::Handle';
}

package Developer::Dashboard::Handle;

sub paths {
    my %paths;
    $paths{ $ENV{D2TG_TEST_DB_ALIAS} } = $ENV{D2TG_TEST_DB_DIR}
      if defined $ENV{D2TG_TEST_DB_ALIAS} && defined $ENV{D2TG_TEST_DB_DIR};
    return \%paths;
}

1;

=head1 NAME

Developer::Dashboard - fake stand-in for cli/* subprocess tests

=head1 DESCRIPTION

A minimal fake of the real Developer Dashboard's C<d2()>/C<paths> API,
used only by tests that spawn a real C<cli/*> subprocess and need
C<D2TG_DB>/C<--db> to resolve to a real, writable scratch directory
without depending on a real Developer Dashboard install being present
(this repo's own Docker test container has no such install - see
t/42-db-flag-cli-integration.t's own skip-guard for the full story).

Tests using this put C<t/lib> ahead of the container's own C<@INC> via
C<$ENV{PERL5LIB}> before spawning the subprocess, and set
C<D2TG_TEST_DB_ALIAS>/C<D2TG_TEST_DB_DIR> so C<paths()> resolves exactly
one alias, to exactly one directory - everything else is deliberately
absent, so an unrelated/typo'd alias still refuses the same way it would
against a real install.

=cut
