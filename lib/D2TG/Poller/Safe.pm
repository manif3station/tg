package D2TG::Poller::Safe;

use strict;
use warnings;
use D2TG::Config;
use D2TG::Store;

sub _sleep {
    my ($seconds) = @_;
    return sleep $seconds;
}

sub classify_store_error {
    my ($error) = @_;

    return
        $error =~ /database is locked/i ? 'database is locked'
      : $error =~ /database.*busy/i     ? 'database is busy'
      : $error =~ /readonly/i           ? 'database is readonly'
      :                                    'an unexpected error';
}

# TGT-314 (found via a scheduled JOB-004 improvement hunt): 12 direct
# call sites across 7 cli/*.pl scripts, plus lib/D2TG/RetryCli.pm's own
# copy, all duplicated this exact shape - classify $@, print a "STORE
# ERROR: <op> failed - <reason>" line, exit 1 - differing only by the
# literal <op> label. Collapsed into this one helper.
sub die_store_error {
    my ( $error, $op_label ) = @_;
    my $reason = classify_store_error($error);
    print STDERR "STORE ERROR: $op_label failed - $reason\n";
    exit 1;
}

sub open_store_or_die {
    my (%args) = @_;

    my $store = eval {
        D2TG::Store->new(
            db_path => D2TG::Config::state_db_path(
                default_root => $args{skill_root},
                base_dir     => $args{base_dir},
            ),
            admin_chat_id => $args{admin_chat_id},
        );
    };
    if ($@) {
        my $reason = classify_store_error($@);
        print STDERR "Failed to open local storage ($reason) - refusing to start.\n";
        exit 1;
    }
    return $store;
}

sub run_once_safe {
    my ( $telegram, $offset, $store, %opts ) = @_;

    my $sleep_fn = delete $opts{sleep} || \&_sleep;

    my $new_offset = eval {
        my ( undef, $off ) = D2TG::Poller::run_once( $telegram, $offset, $store, %opts );
        $off;
    };

    if ($@) {
        my $error = $@;
        unless ( D2TG::Config::is_transient_error($error) ) {
            $error =~ s/\n\z//;
            print STDERR "POLL ERROR: $error\n";
        }
        $sleep_fn->(2);
        return $offset;
    }

    return $new_offset;
}

sub record_message_safe {
    my ( $store, @args ) = @_;

    local $@;
    eval { $store->record_message(@args) };
    if ($@) {
        my $reason = classify_store_error($@);
        print STDERR "record_message failed ($reason) - message was already printed/handled, only its own store record is affected\n";
        return 0;
    }
    return 1;
}

sub record_message_and_track_offset {
    my ( $store, $offset_cap_ref, $update_id, @record_message_safe_args ) = @_;

    my $recorded = record_message_safe( $store, @record_message_safe_args );
    $$offset_cap_ref = $update_id if !$recorded && !defined $$offset_cap_ref;
    return $recorded;
}

sub store_write_safe {
    my ( $chat_id, $description, $code ) = @_;
    my $value = eval { $code->() };
    if ($@) {
        my $reason = classify_store_error($@);
        print STDERR "STORE ERROR [$chat_id]: $description failed - $reason\n";
        return ( 0, undef );
    }
    return ( 1, $value );
}

sub persist_offset_safe {
    my ( $store, $offset, $bot_key ) = @_;

    return 1 unless defined $offset;

    local $@;
    eval { $store->set_offset( $offset, $bot_key ) };
    if ($@) {
        my $reason = classify_store_error($@);
        print STDERR "set_offset failed ($reason) - this poll cycle's offset was not persisted; the in-memory offset is not advanced, so a later cycle retries this same offset (TGT-191)\n";
        return 0;
    }
    return 1;
}

sub skill_version_check_safe {
    my (%args) = @_;

    my $version = eval { D2TG::Config::skill_version(%args) };
    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        print STDERR "skill_version_check_safe: $error - skipping this cycle's version-change check, will retry next cycle\n";
        return undef;
    }
    return $version;
}

1;
