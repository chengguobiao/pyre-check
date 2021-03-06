# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from .. import SUCCESS, get_binary_version
from ..version import __version__
from .command import Command


class Rage(Command):
    NAME = "rage"

    def __init__(self, arguments, configuration, source_directory) -> None:
        super(Rage, self).__init__(arguments, configuration, source_directory)
        self._arguments.command = self.NAME
        self._configuration = configuration

    def _run(self) -> int:
        # Do not use logging. Logging goes to stderr.
        print("Client version:", __version__, flush=True)
        print("Binary path:", self._configuration.get_binary(), flush=True)
        print(
            "Configured binary version:",
            get_binary_version(self._configuration),
            flush=True,
        )
        self._call_client(command=self.NAME, capture_output=False).check()
        return SUCCESS
