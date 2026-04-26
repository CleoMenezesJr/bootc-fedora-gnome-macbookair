#!/bin/bash
# After resume, verify the lid is actually open.
# If closed, re-suspend. Rate limit: if 3+ wakeups in 60s
# with lid closed, disable LID0 wakeup and log for diagnostics.
RATE_FILE="/run/lid-wakeup-count"
TIME_FILE="/run/lid-wakeup-last"

sleep 5

LID_STATE=$(cat /proc/acpi/button/lid/LID0/state 2>/dev/null | awk '{print $2}')

if [ "$LID_STATE" = "closed" ]; then
    NOW=$(date +%s)
    PREV=$(cat "$TIME_FILE" 2>/dev/null || echo 0)
    COUNT=$(cat "$RATE_FILE" 2>/dev/null || echo 0)

    # Reset counter if more than 60s since last event
    if [ $((NOW - PREV)) -gt 60 ]; then
        COUNT=1
    else
        COUNT=$((COUNT + 1))
    fi

    echo "$COUNT" > "$RATE_FILE"
    echo "$NOW" > "$TIME_FILE"

    # If 3+ wakeups in 60s with lid closed -> disable LID0
    if [ "$COUNT" -ge 3 ]; then
        logger -t lid-wakeup-guard "Disabling LID0 wakeup after $COUNT spurious wakeups"
        echo "LID0" > /proc/acpi/wakeup
    fi

    systemctl suspend
else
    # Lid is open — reset counter and re-enable LID0 if needed
    echo "0" > "$RATE_FILE"
    grep -Eqw "LID0.*\*disabled" /proc/acpi/wakeup 2>/dev/null && \
        echo "LID0" > /proc/acpi/wakeup
fi
