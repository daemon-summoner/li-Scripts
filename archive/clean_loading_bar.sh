#!/bin/bash

# Define the total number of tasks
total_tasks=100

# Initialize the progress
progress=0

# Function to draw the progress bar
draw_progress_bar() {
	# Calculate the percentage of completion
	percent=$((100 * $progress / $total_tasks))

	# Define the progress bar characters
	chars=('.' 'o' '0' 'O')
	len=4

	# Initialize the progress bar string
	progress_bar=""

	# Build the progress bar string
	for ((i = 0; i < $percent; i++)); do

		idx=$(($i % $len))
		if [ "$idx" -eq 0 ] || [ "$i" -eq 0 ]; then
			progress_bar+="${chars[0]}"
		else
			progress_bar="${progress_bar%?}"
			progress_bar+="${chars[$idx]}"
		fi
	done

	# Draw the progress bar
	printf "\rProgress: [ %-25s ] %d%%" "$progress_bar" $percent >/dev/tty
}

# Simulate a task
for ((i = 1; i <= total_tasks; i++)); do
	# Update the progress
	progress=$i

	# Draw the progress bar
	draw_progress_bar

	# Simulate a delay
	sleep 0.1
done

# Print a newline at the end
echo
