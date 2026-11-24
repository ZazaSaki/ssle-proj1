#!/bin/bash
# Start the C2 handler and KEEP it listening. Run INSIDE metasploit-container.
# `tail -f /dev/null` holds msfconsole's stdin open so it does not exit after the
# resource script, so the `exploit -j` job's listener stays bound.
cd /root/03-c2
pkill -9 -f msfconsole 2>/dev/null; sleep 2
setsid bash -c 'tail -f /dev/null | msfconsole -q -r /root/03-c2/handler.rc > /root/03-c2/handler.log 2>&1' &
echo "handler launching (pid $!)"
