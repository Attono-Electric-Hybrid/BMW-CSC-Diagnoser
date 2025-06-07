#!/usr/bin/perl

use strict;
use warnings;
use Curses;
use Redis;
use Time::HiRes qw(sleep);

# --- Curses Initialization ---
initscr();      # Initialize the Curses screen
noecho();       # Don't echo user's keypresses
curs_set(0);    # Hide the cursor
nodelay(1);     # Make getch() non-blocking

# --- Color and Layout Setup ---
if (has_colors()) {
    start_color();
    # Initialize color pair 1: White text on a Red background for alerts.
    init_pair(1, COLOR_WHITE, COLOR_RED);
}

# Use the LINES and COLS functions to get screen dimensions.
my ($max_y, $max_x) = (LINES, COLS);

# Increased minimum width for new layout.
if ($max_y < 12 || $max_x < 105) {
    endwin();
    die "Terminal is too small. Minimum size is 105x12.\n";
}

# --- Redis Connection ---
my $redis = Redis->new or die_gracefully("Could not connect to Redis server.");

# --- Main Loop ---
while (1) {
    my $key = getch();
    last if ($key eq 'q');

    my $last_heartbeat = $redis->get('bms:heartbeat') || 0;
    my $heartbeat_age = time() - $last_heartbeat;

    my %display_data;
    if ($heartbeat_age < 10) {
        for my $csc_num (1..6) {
            # CORRECTED: Assign the flat list returned by hgetall to a hash.
            my %voltages = $redis->hgetall("bms:csc:$csc_num");

            # Now iterate over the keys of the correctly populated hash.
            foreach my $cell_num (keys %voltages) {
                $display_data{$csc_num}[$cell_num] = $voltages{$cell_num};
            }
        }
    }

    draw_screen(\%display_data, $heartbeat_age);
    sleep(1);
}
# --- Cleanup ---
endwin(); # Restore terminal settings
exit 0;

#--------------------------------------------------------------------------
# Subroutine: draw_screen
#
# Renders the entire terminal display with conditional highlighting.
#--------------------------------------------------------------------------
sub draw_screen {
    my ($data) = @_;
    erase(); # Clear the screen

    # --- Header ---
    my $time_str = localtime();
    addstr(0, 0, "BMW Cell Voltage Monitor");
    addstr(0, $max_x - length($time_str), $time_str);
    addstr(2, 10, "  1     2     3     4     5     6     7     8     9    10    11    12    13    14    15    16");
    addstr(3, 10, "----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- -----");

    # --- Body ---
    for my $csc_num (1..6) {
        my $y_pos = $csc_num + 3;
        addstr($y_pos, 0, "CSC $csc_num:");

        for my $cell_num (1..16) {
            # New x-position calculation for more space.
            my $x_pos = 10 + (($cell_num - 1) * 6);
            my $voltage_val = $data->{$csc_num}[$cell_num];
            my $display_str = defined($voltage_val) ? $voltage_val : " ... ";

            # --- Conditional Highlighting Logic ---
            my $is_implausible = 0;
            if (defined($voltage_val) && ($voltage_val > 4.2 || $voltage_val < 3.0)) {
                $is_implausible = 1;
            }

            if ($is_implausible) {
                attron(COLOR_PAIR(1));
            }

            addstr($y_pos, $x_pos, $display_str);

            if ($is_implausible) {
                attroff(COLOR_PAIR(1));
            }
        }
    }

    # --- Footer ---
    addstr($max_y - 1, 0, "Press 'q' to exit.");
    refresh(); # Push buffer to terminal
}
#--------------------------------------------------------------------------
# Subroutine: die_gracefully
#
# Ensures Curses is shut down before the program exits on an error.
#--------------------------------------------------------------------------
sub die_gracefully {
    my ($message) = @_;
    endwin();
    die "$message\n";
}