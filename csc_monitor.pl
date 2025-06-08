#!/usr/bin/perl

use strict;
use warnings;
use Curses;
use Redis;
use Time::HiRes qw(sleep);

# Define color pair numbers for clarity
use constant {
    PAIR_DEFAULT    => 0,
    PAIR_ALERT      => 1,
    PAIR_TEMP_OK    => 2,
};

# --- Curses Initialization ---
initscr();
noecho();
curs_set(0);
nodelay(1);

# --- Color and Layout Setup ---
if (has_colors()) {
    start_color();
    init_pair(PAIR_ALERT, COLOR_WHITE, COLOR_RED);
    init_pair(PAIR_TEMP_OK, COLOR_WHITE, COLOR_BLUE);
}

my ($max_y, $max_x) = (LINES, COLS);
if ($max_y < 15 || $max_x < 125) {
    endwin();
    die "Terminal is too small. Minimum size is 125x15.\n";
}

# --- Redis Connection ---
my $redis = Redis->new or die_gracefully("Could not connect to Redis server.");

# --- Main Application Loop ---
my $is_held = 0;
my %display_voltages;
my %display_temps;
my %heartbeat_ages;
my $stats = { total => 0, corrupt => 0 };

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
        for my $csc_num (1..6) {
            my $last_heartbeat = $redis->get("bms:heartbeat:$csc_num") || 0;
            $heartbeat_ages{$csc_num} = time() - $last_heartbeat;
            $display_voltages{$csc_num} = { $redis->hgetall("bms:csc:$csc_num") };
            $display_temps{$csc_num}    = { $redis->hgetall("bms:csc_temps:$csc_num") };
        }
        $stats = {
            total   => $redis->get('bms:stats:total_messages') || 0,
            corrupt => $redis->get('bms:stats:corrupted_frames') || 0,
        };
    }
    
    # 3. Draw the screen with the current state
    draw_screen(\%display_voltages, \%display_temps, \%heartbeat_ages, $is_held, $stats, $max_x, $max_y);
    
    # 4. Wait
    sleep(1);
}

# --- Cleanup ---
endwin();
exit 0;

# --- Subroutines ---

sub draw_screen {
    my ($voltages_ref, $temps_ref, $heartbeat_ages_ref, $is_held, $stats_ref, $max_x, $max_y) = @_;
    erase();

    # --- Header & Footer ---
    my $time_str = localtime();
    addstr(0, 0, "BMW CSC Monitor");
    addstr(0, $max_x - length($time_str), $time_str);
    addstr($max_y - 1, 0, "Press 'q' to quit, 'h' to hold/un-hold.");
    if ($is_held) {
        attron(A_REVERSE);
        addstr($max_y - 1, 40, " [DISPLAY HELD] ");
        attroff(A_REVERSE);
    }
    
    # --- Table Headers ---
    addstr(2, 10, "  1     2     3     4     5     6     7     8     9    10    11    12    13    14    15    16    | Near   Mid    Far ");
    addstr(3, 10, "----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- -----  | ----   ----   ----");

    # --- Table Body ---
    for my $csc_num (1..6) {
        my $y_pos = $csc_num + 3;
        addstr($y_pos, 0, "CSC $csc_num:");

        my $age = $heartbeat_ages_ref->{$csc_num} // 999;
        my $is_stale = ($age > 5 && !$is_held);

        for my $cell_num (1..16) {
            my $x_pos = 10 + (($cell_num - 1) * 6);
            my $v_val = $is_stale ? undef : $voltages_ref->{$csc_num}->{$cell_num};
            my $v_str = defined($v_val) ? sprintf("%4.2f", $v_val) : "....";
            
            if (defined($v_val) && ($v_val > 4.2 || $v_val < 3.0)) {
                attron(COLOR_PAIR(PAIR_ALERT));
            }
            addstr($y_pos, $x_pos, $v_str);
            attroff(COLOR_PAIR(PAIR_ALERT));
        }

        addstr($y_pos, 107, "|");
        my @sensors = ({ num => 1, x => 109 }, { num => 3, x => 116 }, { num => 2, x => 122 });

        foreach my $sensor (@sensors) {
            my $t_val = $is_stale ? undef : $temps_ref->{$csc_num}->{$sensor->{num}};
            my $t_str = defined($t_val) ? sprintf("%4.1f", $t_val) : "....";
            
            my $color_pair = PAIR_DEFAULT;
            if (defined($t_val)) {
                $color_pair = ($t_val < 0 || $t_val > 50) ? PAIR_ALERT : PAIR_TEMP_OK;
            }
            attron(COLOR_PAIR($color_pair));
            addstr($y_pos, $sensor->{x}, $t_str);
            attroff(COLOR_PAIR($color_pair));
        }
    }
    
    # --- Statistics Display ---
    my $corruption_rate = ($stats_ref->{total} > 0) ? ($stats_ref->{corrupt} / $stats_ref->{total}) * 100 : 0;
    my $stats_y_pos = 11;

    addstr($stats_y_pos, 0, "--- Statistics ---");
    addstr($stats_y_pos + 1, 0, "Total Messages Seen: $stats_ref->{total}");
    addstr($stats_y_pos + 2, 0, "Corrupted Frames:    $stats_ref->{corrupt}");
    addstr($stats_y_pos + 3, 0, "Corruption Rate:     " . sprintf("%.2f%%", $corruption_rate));

    refresh();
}

sub die_gracefully {
    my ($message) = @_;
    endwin();
    die "$message\n";
}
