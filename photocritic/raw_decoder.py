"""RawDecoder abstraction — the rest of the app must not depend on a particular backend."""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import rawpy


@dataclass
class DecodedRaw:
    rgb: np.ndarray  # HxWx3 uint8
    raw_width: int
    raw_height: int


class RawDecoder(ABC):
    @abstractmethod
    def decode(self, path: Path) -> DecodedRaw: ...


class LibRawDecoder(RawDecoder):
    """Decodes via rawpy (LibRaw bindings). Source files are opened read-only;
    nothing is ever written back to the original path."""

    def decode(self, path: Path) -> DecodedRaw:
        with rawpy.imread(str(path)) as raw:
            rgb = raw.postprocess(
                use_camera_wb=True,
                half_size=False,
                no_auto_bright=False,
                output_bps=8,
            )
        h, w = rgb.shape[:2]
        return DecodedRaw(rgb=rgb, raw_width=w, raw_height=h)


def default_decoder() -> RawDecoder:
    return LibRawDecoder()
