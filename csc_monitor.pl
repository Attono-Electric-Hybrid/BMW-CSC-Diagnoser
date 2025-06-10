#!/usr/bin/perl

use strict;
use warnings;
use Curses;
use Redis;
use Time::HiRes qw(sleep);
use List::Util qw(sum min);

# Define color pair numbers for clarity
use constant {
    PAIR_DEFAULT          => 0,
    PAIR_ALERT_CRITICAL   => 1, # White on Red
    PAIR_TEMP_OK          => 2, # White on Blue
    PAIR_ALERT_WARN_TEMP  => 3, # Black on Yellow
};

# --- Curses Initialization ---
initscr();
noecho();
curs_set(0);
nodelay(1);

# --- Color and Layout Setup ---
if (has_colors()) {
    start_color();
    init_pair(PAIR_ALERT_CRITICAL,  COLOR_WHITE, COLOR_RED);
    init_pair(PAIR_TEMP_OK,         COLOR_WHITE, COLOR_BLUE);
    init_pair(PAIR_ALERT_WARN_TEMP, COLOR_BLACK, COLOR_YELLOW);
}

my ($max_y, $max_x) = (LINES, COLS);
if ($max_y < 18 || $max_x < 140) {
    endwin();
    die "Terminal is too small. Minimum size is 140x18.\n";
}

# --- Redis Connection ---
my $redis = Redis->new or die_gracefully("Could not connect to Redis server.");

# --- Main Application Loop ---
my $is_held = 0;
my %display_data;
my $stats = { total => 0, corrupt => 0 };
my $median_temp = 0;
my %csc_status;

while (1) {
    # 1. Check for user input
    my $key = getch();
    if (defined $key) {
        last if ($key eq 'q');
        if ($key eq 'h') {
            $is_held = !$is_held;
        }
    }

    # 2. Fetch new data only if display is NOT held
    if (!$is_held) {
        my @all_temps;
        %display_data = ();
        
        my %csc_frequencies;
        for my $csc_num (1..6) {
            $csc_frequencies{$csc_num} = $redis->zcard("bms:msg_times:$csc_num");
        }
        my @active_freqs = grep { $_ > 0 } values %csc_frequencies;
        my $min_freq = @active_freqs ? min(@active_freqs) : 0;
        
        %csc_status = ();
        for my $csc_num (1..6) {
            my $freq = $csc_frequencies{$csc_num};
            if ($freq == 0) {
                $csc_status{$csc_num} = 'Absent';
            } elsif ($min_freq > 0 && $freq > ($min_freq * 1.5) && scalar(@active_freqs) > 1) {
                $csc_status{$csc_num} = 'Duplicate';
            } else {
                $csc_status{$csc_num} = 'Seen';
            }

            if ($csc_status{$csc_num} eq 'Seen') {
                $display_data{$csc_num}{voltages} = { $redis->hgetall("bms:csc:$csc_num") };
                $display_data{$csc_num}{total_v}  = $redis->get("bms:csc_total_v:$csc_num");
                my $temps = { $redis->hgetall("bms:csc_temps:$csc_num") };
                $display_data{$csc_num}{temps} = $temps;
                push @all_temps, values %{$temps};
            }
        }
        
        if (scalar @all_temps >= 5) {
            my @sorted_temps = sort { $a <=> $b } @all_temps;
            $median_temp = $sorted_temps[int(@sorted_temps / 2)];
        } else {
            $median_temp = 0;
        }

        $stats = {
            total   => $redis->get('bms:stats:total_messages') || 0,
            corrupt => $redis->get('bms:stats:corrupted_frames') || 0,
        };
    }
    
    # 3. Draw the screen
    draw_screen(\%display_data, $is_held, $stats, $median_temp, \%csc_status, $max_x, $max_y);
    
    # 4. Wait
    sleep(1);
}

# --- Cleanup ---
endwin();
exit 0;

# --- Subroutines ---

sub draw_screen {
    my ($data_ref, $is_held, $msg_stats, $median_temp, $csc_status_ref, $max_x, $max_y) = @_;
    erase();

    my $left_margin = 1;

    # --- Header & Footer ---
    my $time_str = localtime();
    my $copyright = "(C) Attono Electric & Hybrid (Attono Limited)";
    addstr(0, $left_margin, "BMW CSC Monitor");
    addstr(0, $max_x - length($time_str) - $left_margin, $time_str);
    addstr($max_y - 1, $left_margin, "Press 'q' to quit, 'h' to hold/un-hold.");
    addstr($max_y - 1, $max_x - length($copyright) - $left_margin, $copyright);

    if ($is_held) {
        attron(A_REVERSE);
        addstr($max_y - 1, 40 + $left_margin, " [DISPLAY HELD] ");
        attroff(A_REVERSE);
    }
    
    # --- Table Headers ---
    addstr(2, 10 + $left_margin, "  1     2     3     4     5     6     7     8     9    10    11    12    13    14    15    16   | Total V | Near   Mid    Far");
    addstr(3, 10 + $left_margin, "----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- | ------- | ----   ----   ----");

    # --- Table Body ---
    for my $csc_num (1..6) {
        my $y_pos = $csc_num + 3;
        addstr($y_pos, $left_margin, "CSC $csc_num:");

        my $voltages_ref = $data_ref->{$csc_num}{voltages} || {};
        my $temps_ref    = $data_ref->{$csc_num}{temps}    || {};
        my $total_v      = $data_ref->{$csc_num}{total_v};
        
        my $status = $csc_status_ref->{$csc_num} || 'Absent';
        my $is_stale = ($status ne 'Seen');
        
        for my $cell_num (1..16) {
            my $x_pos = 10 + $left_margin + (($cell_num - 1) * 6);
            my $v_val = ($is_held || $is_stale) ? undef : $voltages_ref->{$cell_num};
            my $v_str = defined($v_val) ? sprintf("%4.2f", $v_val) : "....";
            
            if (defined($v_val) && ($v_val > 4.2 || $v_val < 3.0)) {
                attron(COLOR_PAIR(PAIR_ALERT_CRITICAL));
            }
            addstr($y_pos, $x_pos, $v_str);
            attroff(COLOR_PAIR(PAIR_ALERT_CRITICAL));
        }

        addstr($y_pos, 106 + $left_margin, "|");
        my $total_v_str = ($is_held || $is_stale || !defined($total_v)) ? "..." : sprintf("%7.3f", $total_v / 1000);
        addstr($y_pos, 107 + $left_margin, $total_v_str);
        
        addstr($y_pos, 116 + $left_margin, "|");
        my @sensors = ({ num => 1, x => 118 }, { num => 3, x => 125 }, { num => 2, x => 132 });

        foreach my $sensor (@sensors) {
            my $t_val = ($is_held || $is_stale) ? undef : $temps_ref->{$sensor->{num}};
            my $t_str = defined($t_val) ? sprintf("%4.1f", $t_val) : "....";
            
            my $color_pair = PAIR_DEFAULT;
            if (defined($t_val)) {
                my $deviation = $median_temp > 0 ? abs($t_val - $median_temp) : 0;
                if ($t_val < 0 || $t_val > 50 || ($median_temp > 0 && $deviation > 4)) {
                    $color_pair = PAIR_ALERT_CRITICAL;
                } elsif ($median_temp > 0 && $deviation > 2) {
                    $color_pair = PAIR_ALERT_WARN_TEMP;
                } else {
                    $color_pair = PAIR_TEMP_OK;
                }
            }
            attron(COLOR_PAIR($color_pair));
            addstr($y_pos, $sensor->{x} + $left_margin, $t_str);
            attroff(COLOR_PAIR($color_pair));
        }
    }
    
    # --- Statistics & Status Panel ---
    my $corruption_rate = ($msg_stats->{total} > 0) ? ($msg_stats->{corrupt} / $msg_stats->{total}) * 100 : 0;
    my $stats_y_pos = 11;

    addstr($stats_y_pos, $left_margin, "--- Statistics ---");
    addstr($stats_y_pos + 1, $left_margin, "Total Messages Seen: $msg_stats->{total}");
    addstr($stats_y_pos + 2, $left_margin, "Corrupted Frames:    $msg_stats->{corrupt}");
    addstr($stats_y_pos + 3, $left_margin, "Corruption Rate:     " . sprintf("%.2f%%", $corruption_rate));
    addstr($stats_y_pos + 4, $left_margin, sprintf("Global Temp Median: %.2fC", $median_temp));

    my $status_x_pos = 119; # Moved to below statistics
    addstr($stats_y_pos, $status_x_pos, "--- CSC Status ---");
    
    for my $csc_num (1..6) {
        my $status = $csc_status_ref->{$csc_num} || 'Absent';
        my $status_str = sprintf("CSC %d: %-9s", $csc_num, $status);
        
        my $color_pair = PAIR_DEFAULT;
        if ($status eq 'Duplicate' or $status eq 'Absent') {
            $color_pair = PAIR_ALERT_CRITICAL;
        }

        attron(COLOR_PAIR($color_pair));
        addstr($stats_y_pos + 1 + $csc_num, $status_x_pos, $status_str);
        attroff(COLOR_PAIR($color_pair));
    }

    refresh();
}

sub die_gracefully {
    my ($message) = @_;
    endwin();
    die "$message\n";
}
