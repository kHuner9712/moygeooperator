from dataclasses import dataclass
from typing import Protocol


class SideEffectNotAttempted(RuntimeError):
    """The plugin failed before invoking the irreversible browser action."""


@dataclass(frozen=True, slots=True)
class PlatformObservation:
    response_text: str
    streaming_indicator_absent: bool
    stop_control_absent: bool
    input_ready: bool
    response_text_stable: bool
    final_response_element_present: bool
    platform_error_absent: bool

    @property
    def complete(self) -> bool:
        return all(
            (
                self.streaming_indicator_absent,
                self.stop_control_absent,
                self.input_ready,
                self.response_text_stable,
                self.final_response_element_present,
                self.platform_error_absent,
            )
        )


@dataclass(frozen=True, slots=True)
class RevalidationResult:
    safe: bool
    resume_state: str | None
    pause_reason: str | None
    details: str = ""


class PlatformPlugin(Protocol):
    name: str
    phase: int

    async def detect_login(self, page: object) -> bool: ...
    async def detect_human_intervention(self, page: object) -> str | None: ...
    async def open_platform(self, page: object) -> None: ...
    async def send_query(self, page: object, prompt: str) -> None: ...
    async def observe_response(self, page: object) -> PlatformObservation: ...
    async def delete_chat(self, page: object) -> None: ...
    async def verify_chat_deleted(self, page: object) -> bool: ...
    async def revalidate(
        self, page: object, execution: dict[str, object]
    ) -> RevalidationResult: ...
