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
    # Pair 1: White text on a Red background for alerts.
    init_pair(PAIR_ALERT, COLOR_WHITE, COLOR_RED);
    # Pair 2: White text on a Blue background for normal temperatures.
    init_pair(PAIR_TEMP_OK, COLOR_WHITE, COLOR_BLUE);
}

my ($max_y, $max_x) = (LINES, COLS);
# Increased minimum width for new layout including temperatures.
if ($max_y < 12 || $max_x < 125) {
    endwin();
    die "Terminal is too small. Minimum size is 125x12.\n";
}

# --- Redis Connection ---
my $redis = Redis->new or die_gracefully("Could not connect to Redis server.");

# --- Main Application Loop ---
while (1) {
    my $key = getch();
    last if ($key eq 'q');

    # --- Data Aggregation ---
    my $last_heartbeat = $redis->get('bms:heartbeat') || 0;
    my $heartbeat_age = time() - $last_heartbeat;
    
    my %display_voltages;
    my %display_temps;

    if ($heartbeat_age < 10) {
        for my $csc_num (1..6) {
            # Get all voltages for the CSC
            my %v_data = $redis->hgetall("bms:csc:$csc_num");
            foreach my $cell_num (keys %v_data) {
                $display_voltages{$csc_num}[$cell_num] = $v_data{$cell_num};
            }
            # Get all temperatures for the CSC
            my %t_data = $redis->hgetall("bms:csc_temps:$csc_num");
            foreach my $sensor_num (keys %t_data) {
                $display_temps{$csc_num}[$sensor_num] = $t_data{$sensor_num};
            }
        }
    }

    draw_screen(\%display_voltages, \%display_temps, $heartbeat_age);
    sleep(1);
}

# --- Cleanup ---
endwin();
exit 0;

# --- Subroutines ---

#--------------------------------------------------------------------------
# Subroutine: draw_screen
#
# Renders the entire terminal display with conditional highlighting
# and final layout adjustments.
#--------------------------------------------------------------------------
sub draw_screen {
    my ($voltages, $temps, $heartbeat_age) = @_;
    erase(); # Clear the screen

    # --- Header ---
    my $time_str = localtime();
    addstr(0, 0, "BMW CSC Monitor");
    addstr(0, $max_x - length($time_str), $time_str);
    
    # --- Stale Data Check ---
    if ($heartbeat_age > 5) {
        my $warning = "STALE DATA: HANDLER NOT RUNNING OR UNRESPONSIVE";
        attron(COLOR_PAIR(PAIR_ALERT));
        addstr(int($max_y / 2), int(($max_x - length($warning)) / 2), $warning);
        attroff(COLOR_PAIR(PAIR_ALERT));
        addstr($max_y - 1, 0, "Press 'q' to exit.");
        refresh();
        return;
    }
    
    # --- Table Headers (Final Spacing) ---
    addstr(2, 10, "  1     2     3     4     5     6     7     8     9    10    11    12    13    14    15   16   |  T1   T2   T3");
    addstr(3, 10, "----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ---- | ---- ---- ----");

    # --- Table Body ---
    for my $csc_num (1..6) {
        my $y_pos = $csc_num + 3;
        addstr($y_pos, 0, "CSC $csc_num:");

        # Display Voltages
        for my $cell_num (1..16) {
            my $x_pos = 10 + (($cell_num - 1) * 6);
            my $v_val = $voltages->{$csc_num}[$cell_num];
            my $v_str = defined($v_val) ? sprintf("%4.2f", $v_val) : "....";
            
            if (defined($v_val) && ($v_val > 4.2 || $v_val < 3.0)) {
                attron(COLOR_PAIR(PAIR_ALERT));
            }
            addstr($y_pos, $x_pos, $v_str);
            attroff(COLOR_PAIR(PAIR_ALERT));
        }

        # Display Temperatures (Final Spacing)
        addstr($y_pos, 105, "|"); # UPDATED: y-offset set to 106
        for my $sensor_num (1..3) {
            # UPDATED: x-offset set to 108
            my $x_pos = 107 + (($sensor_num - 1) * 5);
            my $t_val = $temps->{$csc_num}[$sensor_num];
            my $t_str = defined($t_val) ? sprintf("%4.1f", $t_val) : "....";
            
            my $color_pair = PAIR_DEFAULT;
            if (defined($t_val)) {
                if ($t_val < 0 || $t_val > 50) {
                    $color_pair = PAIR_ALERT;
                } else {
                    $color_pair = PAIR_TEMP_OK;
                }
            }
            
            attron(COLOR_PAIR($color_pair));
            addstr($y_pos, $x_pos, $t_str);
            attroff(COLOR_PAIR($color_pair));
        }
    }

    # --- Footer ---
    addstr($max_y - 1, 0, "Press 'q' to exit.");
    refresh();
}

sub die_gracefully {
    my ($message) = @_;
    endwin();
    die "$message\n";
}