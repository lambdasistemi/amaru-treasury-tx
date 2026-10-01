# data model — #514

No new or changed data types. D-1: the terminal's attribute state
(`TerminalAttributes` of the `/dev/tty` fd) is the only state; it is
echo-off for the whole interval from before the first prompt byte to
the end of the line read, and equal to its entry value on every exit
(INV-1, INV-4).
