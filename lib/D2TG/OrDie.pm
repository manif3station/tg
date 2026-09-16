package D2TG::OrDie;

use strict;
use warnings;

# TGT-269: extract_bot_flag_or_die (D2TG::Reply::Args),
# extract_db_flag_or_die (D2TG::Config::Flags), and
# resolve_alias_dir_or_die/require_existing_base_dir_or_die
# (D2TG::Config::Paths) each independently hand-rolled the identical
# eval/print-STDERR/exit(1) wrapper idiom - only the wrapped function
# and its return shape (scalar vs list) differed. Extracted here as a
# deliberate leaf module with zero use-dependencies on D2TG::Config/
# D2TG::Config::Paths/D2TG::Reply, to avoid the circular-use trap:
# D2TG::Config already uses D2TG::Config::Paths, so Config::Paths
# cannot use Config back, and a shared helper needed by both plus
# D2TG::Reply::Args must live outside that whole family entirely.
sub or_die {
    my ( $coderef, @args ) = @_;

    my @result = eval { $coderef->(@args) };
    if ($@) {
        print STDERR $@;
        exit 1;
    }

    return wantarray ? @result : $result[0];
}

1;
