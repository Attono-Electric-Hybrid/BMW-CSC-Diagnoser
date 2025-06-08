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
if ($max_y < 12 || $max_x < 125) {
    endwin();
    die "Terminal is too small. Minimum size is 125x12.\n";
}

# --- Redis Connection ---
my $redis = Redis->new or die_gracefully("Could not connect to Redis server.");

# --- Main Application Loop ---
my $is_held = 0;
my %display_voltages;
my %display_temps;
my $heartbeat_age;

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
        $heartbeat_age = time() - ($redis->get('bms:heartbeat') || 0);

        # Always fetch the latest data. The draw_screen function will
        # decide whether to show it or a stale warning.
        for my $csc_num (1..6) {
            $display_voltages{$csc_num} = { $redis->hgetall("bms:csc:$csc_num") };
            $display_temps{$csc_num}    = { $redis->hgetall("bms:csc_temps:$csc_num") };
        }
    }

    # 3. Draw the screen with the most recently fetched data and status
    draw_screen(\%display_voltages, \%display_temps, $heartbeat_age, $is_held);

    # 4. Wait for the next cycle
    sleep(1);
}

# --- Cleanup ---
endwin();
exit 0;

# --- Subroutines ---

sub draw_screen {
    my ($voltages_ref, $temps_ref, $heartbeat_age, $is_held) = @_;
    erase();

    # --- Header ---
    my $time_str = localtime();
    addstr(0, 0, "BMW CSC Monitor");
    addstr(0, $max_x - length($time_str), $time_str);

    # --- Footer (drawn early to show hold status even with stale data) ---
    addstr($max_y - 1, 0, "Press 'q' to quit, 'h' to hold/un-hold.");
    if ($is_held) {
        attron(A_REVERSE);
        addstr($max_y - 1, 40, " [DISPLAY HELD] ");
        attroff(A_REVERSE);
    }

    # --- Stale Data Check ---
    if ($heartbeat_age > 5 && !$is_held) {
        my $warning = "STALE DATA: HANDLER NOT RUNNING OR UNRESPONSIVE";
        attron(COLOR_PAIR(PAIR_ALERT));
        addstr(int($max_y / 2), int(($max_x - length($warning)) / 2), $warning);
        attroff(COLOR_PAIR(PAIR_ALERT));
        refresh();
        return; # Do not draw the table
    }
    
    # --- Table Headers ---
    addstr(2, 10, "  1     2     3     4     5     6     7     8     9    10    11    12    13    14    15   16  | Near   Mid    Far");
    addstr(3, 10, "----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ---- | ----   ----   ----");

    # --- Table Body ---
    for my $csc_num (1..6) {
        my $y_pos = $csc_num + 3;
        addstr($y_pos, 0, "CSC $csc_num:");

        for my $cell_num (1..16) {
            my $x_pos = 10 + (($cell_num - 1) * 6);
            my $v_val = $voltages_ref->{$csc_num}->{$cell_num};
            my $v_str = defined($v_val) ? sprintf("%4.2f", $v_val) : "....";
            
            if (defined($v_val) && ($v_val > 4.2 || $v_val < 3.0)) {
                attron(COLOR_PAIR(PAIR_ALERT));
            }
            addstr($y_pos, $x_pos, $v_str);
            attroff(COLOR_PAIR(PAIR_ALERT));
        }

        addstr($y_pos, 106, "|");
        my @sensors = ({ num => 1, x => 108 }, { num => 3, x => 115 }, { num => 2, x => 122 });

        foreach my $sensor (@sensors) {
            my $t_val = $temps_ref->{$csc_num}->{$sensor->{num}};
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
    
    refresh();
}

sub die_gracefully {
    my ($message) = @_;
    endwin();
    die "$message\n";
}
