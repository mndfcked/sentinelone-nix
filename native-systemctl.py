#!@python@
import os
import sys

REAL_SYSTEMCTL = "@realSystemctl@"


def forwarded_arguments(arguments):
    if arguments == ["enable", "sentinelone.service"] or arguments == [
        "disable",
        "sentinelone.service",
    ]:
        return ["--runtime", *arguments]
    return arguments


def main():
    arguments = forwarded_arguments(sys.argv[1:])
    os.execv(REAL_SYSTEMCTL, [REAL_SYSTEMCTL, *arguments])


if __name__ == "__main__":
    main()
