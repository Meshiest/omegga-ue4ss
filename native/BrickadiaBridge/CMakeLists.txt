# Built through the UE4SS tree: pass -DUE4SS_EXTRA_CPPMODS=<this dir> when configuring it.
# UE4SS loads Mods/BrickadiaBridge/dlls/main.so.
add_library(BrickadiaBridge SHARED src/main.cpp src/socket.cpp src/allocator.cpp)
target_link_libraries(BrickadiaBridge PRIVATE UE4SS)
# The server exports operator new/delete (backed by snmalloc) and libUE4SS.so re-exports
# its static libstdc++ ones, so an undefined reference here binds to the game's at run
# time while libUE4SS allocates from libc; a string made in one and freed in the other
# aborts with "snmalloc heap corruption: Not allocated by snmalloc". allocator.cpp
# defines them over malloc, and -Bsymbolic keeps those definitions local.
target_link_options(BrickadiaBridge PRIVATE -static-libstdc++ -Wl,-Bsymbolic)
set_target_properties(BrickadiaBridge PROPERTIES OUTPUT_NAME main PREFIX "" CXX_VISIBILITY_PRESET hidden)
