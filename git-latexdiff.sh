#! /bin/bash

# Main author: Matthieu Moy <Matthieu.Moy@imag.fr> (2012, 2013)
# (See the Git history for other contributors)
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.
#
# git-latexdiff is a wrapper around latexdiff
# (http://www.ctan.org/pkg/latexdiff) that allows using it to diff two
# revisions of a LaTeX file.
#
# The script internally checks out the full tree for the specified
# revisions, calls latexpand to flatten the document and then calls
# latexdiff, hence this works if the document is split into multiple
# .tex files.
#
# Try "git latexdiff -h" for more information.
#
# To install, just copy git-latexdiff in your $PATH.

# Missing features (patches welcome ;-):
# - diff the index
# - hardlink temporary checkouts as much as possible

# Alternatives:
#
# There is another script doing essentially the same here:
# https://github.com/cawka/latexdiff/blob/master/latexdiff-git
# My experience is that latexdiff-git is more buggy than
# git-latexdiff, but they probably just don't have the same bugs ;-)
#
# There are a bunch of other alternatives cited here:
#
#   http://tex.stackexchange.com/questions/1325/using-latexdiff-with-git
#
# Ideally, these scripts should be merged.

set -o errexit
set -o noclobber

git_latexdiff_version=1.0

usage () {
    cat << EOF
Usage: $(basename $0) [options] OLD [NEW]
       $(basename $0) [options] OLD --
       $(basename $0) [options] -- OLD
Call latexdiff on two Git revisions of a file.

OLD and NEW are Git revision identifiers. NEW defaults to HEAD.
If "--" is used for NEW, then diff against the working directory.

Options:
    --help                this help message
    --main <file.tex>     name of the main LaTeX file
    --no-view             don't display the resulting PDF file
    --bibtex, -b          run bibtex as well as latex
                             (pdflatex,bibtex,pdflatex,pdflatex)
    --biber               run BibLaTex-Biber as well as latex
                             (pdflatex,bibtex,pdflatex,pdflatex)
    --view                view the resulting PDF file
                            (default if -o is not used)
    --pdf-viewer <cmd>    use <cmd> to view the PDF file (default: \$PDFVIEWER)
    --no-cleanup          don't cleanup temp dir after running
    --no-flatten          don't call latexpand to flatten the document
    --cleanup MODE        Cleanup temporary files according to MODE:

                           - keeppdf (default): keep only the
                                  generated PDF file

                           - none: keep all temporary files
                                  (may eat your diskspace)

                           - all: erase all generated files.
                                  Problematic with --view when the
                                  viewer is e.g. evince, and doesn't
                                  like when the file being viewed is
                                  deleted.

    --latexmk             use latexmk
    --latexopt            pass additional options to latex (e.g. -shell-escape)
    -o <file>, --output <file>
                          copy resulting PDF into <file> (usually ending with .pdf)
                          Implies "--cleanup all"
    --tmpdirprefix        where temporary directory will be created (default: /tmp)
    --verbose, -v         give more verbose output
    --quiet               redirect output from subprocesses to log files
    --prepare <cmd>       run <cmd> before latexdiff (e.g. run make to generate
                             included files)
    --ln-untracked        symlink uncommited files from the working directory
    --version             show git-latexdiff version.
    --subtree             checkout the tree at and below the main file
                             (enabled by default, disable with --whole-tree)
    --whole-tree          checkout the whole tree (contrast with --subtree)
    --ignore-latex-errors keep on going even if latex gives errors, so long as
                          a PDF file is produced
    --ignore-makefile     ignore the Makefile, build as though it doesn't exist
    -*                    other options are passed directly to latexdiff
    --bbl                 shortcut to flatten a bbl file of the same name as the project
    --latexpand           pass options to lastexpand (should be last option specified)
    --latexdiff-flatten   use --flatten from latexdiff instead of latexpand
EOF
}

die () {
    echo "fatal: $@"
    exit 1
}

verbose () {
    if test "$verbose" = 1 ; then
	printf "%s ..." "$@"
    fi
}

verbose_progress () {
    if test "$verbose" = 1 ; then
	printf "." "$@"
    fi
}

verbose_done () {
    if test "$verbose" = 1 ; then
	echo " ${1:-done}."
    fi
}

verbose_say () {
    if test "$verbose" = 1 ; then
	printf "%s\n" "$@"
    fi
}

old=
new=
main=
view=maybe
cleanup=keeppdf
verbose=0
bibtex=0
biber=0
output=
initial_dir=$PWD
initial_repo=$(git rev-parse --show-toplevel)
tmpdir_prefix="/tmp"
prepare_cmd=
flatten=1
subtree=1
uselatexmk=
latexopt=
ln_untracked=0
quiet=0
ignorelatexerrors=0
latexdiffopt=()
latexpand=()
workingdir=()
bbl=0
latexdiff_flatten=0

while test $# -ne 0; do
    case "$1" in
        "--help"|"-h")
            usage
            exit 0
            ;;
	"--main")
	    test $# -gt 1 && shift || die "missing argument for $1"
	    main=$1
	    ;;
	"--no-view")
	    view=0
	    ;;
	"--view")
	    view=1
	    ;;
	"--pdf-viewer")
	    test $# -gt 1 && shift || die "missing argument for $1"
	    PDFVIEWER="$1"
	    ;;
	"--no-cleanup")
	    cleanup=none
	    ;;
	"--ignore-latex-errors")
	    ignorelatexerrors=1
	    ;;
        "--cleanup")
            shift
            case "$1" in
                "none"|"all"|"keeppdf")
                    cleanup="$1"
                    ;;
                *)
                    echo "Bad argument --cleanup $1"
                    usage
                    exit 1
                    ;;
            esac
            ;;
	"--no-flatten")
            flatten=0
            ;;
	"--ignore-makefile")
	    ignoremake=1
	    ;;
	"-o"|"--output")
	    test $# -gt 1 && shift || die "missing argument for $1"
	    output=$1
	    cleanup=all
	    ;;
	"-b"|"--bibtex")
	    bibtex=1
	    ;;
	"--biber")
	    biber=1
	    ;;
	"--verbose"|"-v")
	    verbose=1
	    ;;
        "--quiet")
	    quiet=1
	    ;;
	"--version")
	    echo "$git_latexdiff_version"
            exit 0
	    ;;
	"--subtree")
	    subtree=1
	    ;;
	"--whole-tree")
	    subtree=0
	    ;;
	"--prepare")
	    shift
	    prepare_cmd="$1"
	    ;;
        "--latexmk")
            uselatexmk=1
            ;;
	"--latexpand")
	    shift
	    latexpand=$1
	    ;;
	"--bbl")
	    bbl=1
	    ;;
	"--latexdiff-flatten")
	    latexdiff_flatten=1
            flatten=0
	    ;;
	"--latexopt")
	    shift
	    latexopt=$1
	    ;;
        "--ln-untracked")
            ln_untracked=1
            ;;
        "--no-ln-untracked")
            ln_untracked=0
            ;;
        "--tmpdirprefix")
	    shift
	    tmpdir_prefix="$1"
	    ;;
        -*)
            if test "$1" = "--" ; then
                if test -z "$new" ; then
                    new=$1
                else
                    echo "Bad argument $1"
                    usage
                    exit 1
                fi
            else
                latexdiffopt+=("$1")
            fi
            ;;
        *)
	    if test -z "$1" ; then
		echo "Empty string not allowed as argument"
		usage
		exit 1
	    elif test -z "$old" ; then
		old=$1
	    elif test -z "$new" ; then
		new=$1
	    else
		echo "Bad argument $1"
		usage
		exit 1
	    fi
            ;;
    esac
    shift
done

if test -z "$new" ; then
    new=HEAD
fi
if test "$new" = "--"; then
    ln_untracked=1
fi

if test -z "$old" ; then
    echo "fatal: Please, provide at least one revision to diff with."
    usage
    exit 1
fi

if test -z "$PDFVIEWER" ; then
    verbose "Auto-detecting PDF viewer"
    candidates="xdg-open evince okular xpdf acroread"
    if test "$(uname)" = Darwin ; then
        # open exists on GNU/Linux, but does not open PDFs
	candidates="open $candidates"
    fi

    for command in $candidates; do
	if command -v "$command" >/dev/null 2>&1; then
	    PDFVIEWER="$command"
	    break
	else
	    verbose_progress
	fi
    done
    verbose_done "$PDFVIEWER"
fi

case "$view" in
    maybe|1)
	if test -z "$PDFVIEWER" ; then
	    echo "warning: could not find a PDF viewer on your system."
	    echo "warning: Please set \$PDFVIEWER or use --pdf-viewer CMD."
	    PDFVIEWER=false
	fi
	;;
esac

if test $flatten = 1 &&
    ! command -v latexpand 2>/dev/null; then
    echo "Warning: latexpand not found. Falling back to latexdiff --flatten."
    latexdiff_flatten=1
    flatten=0
fi

## end option parsing ##

check_knitr () {
    if test -z "$prepare_cmd"; then
	prepare_cmd="Rscript -e \"library(knitr); knit('$main')\""
    fi
    main="${main%\.*}.tex"
}

log_cmd () {
    log=$1
    shift
    if [ "$quiet" = 1 ]; then
	"$@" >$log 2>&1
    else
	"$@"
    fi
}

# main is relative to initial_dir (if returned)
if test -z "$main" ; then
    printf "%s" "No --main provided, trying to guess ... "
    main=$(git grep -l '^[ \t]*\\documentclass')
    # May return multiple results, but if so the result won't be a file.
    if test -r "$main" ; then
	echo "Using $main as the main file."
    else
	if test -z "$main" ; then
	    echo "No candidate for main file."
	else
	    echo "Multiple candidates for main file:"
	    printf "%s\n" "$main" | sed 's/^/\t/'
	fi
	die "Please, provide a main file with --main FILE.tex."
    fi
fi

ext=${main##*\.}
case "$ext" in
    Rnw) check_knitr ;;
    Rtex) check_knitr ;;
    *) ;;
esac

if test ! -r "$main" ; then
    die "Cannot read $main."
fi

verbose "Creating temporary directories"

git_prefix=$(git rev-parse --show-prefix)
git_dir="$(git rev-parse --git-dir)" || die "Not a git repository?"
cd "$(git rev-parse --show-cdup)" || die "Can't cd back to repository root"
git_dir=$(cd "$git_dir"; pwd)

# make main relative to git root directory
if test -n "$git_prefix" ; then
    main=$git_prefix$main
fi
mainbase=$(basename "$main" .tex)
maindir=$(dirname "$main")

tmpdir=$tmpdir_prefix/git-latexdiff.$$
mkdir "$tmpdir" || die "Cannot create temporary directory."

cd "$tmpdir" || die "Cannot cd to $tmpdir"

mkdir old new || die "Cannot create old and new directories."

verbose_done
verbose_say "Temporary directories: $tmpdir/old and $tmpdir/new"
verbose "Checking out old and new version"

cd old || die "Cannot cd to old/"
if test "$ln_untracked" = 1; then
    (
       mkdir -p "$maindir" && cd "$maindir" && ln -s "$initial_repo"/"$maindir"/* .
    )
fi

if test "$subtree" = 1; then
    checkoutroot=$git_prefix
else
    checkoutroot="."
fi

# Checkout a subtree, without touching the index ("git checkout" would)
(cd "$git_dir" && git archive --format=tar "$old" "$checkoutroot") | tar -xf -
verbose_progress
cd ../new || die "Cannot cd to new/"
if test "$ln_untracked" = 1; then
    (
       mkdir -p "$maindir" && cd "$maindir" && ln -s "$initial_repo"/"$maindir"/* .
    )
fi
if test "$new" != "--"; then
    # if new == "--" then diff working dir (already there thanks to ln
    # -s above).
    (cd "$git_dir" && git archive --format=tar "$new" "$checkoutroot") | tar -xf -
fi
verbose_progress
cd ..

verbose_done

for dir in old new
do
    verbose "Running preparation command $prepare_cmd in $dir/$git_prefix"
    ( cd "$dir/$git_prefix/" && log_cmd prepare.log eval "$prepare_cmd" )
    if test ! -f "$dir/$main"; then
	die "$prepare_cmd did not produce $dir/$main."
    fi
    verbose_done
done

# Option to use latexdiff --flatten instead of latexpand
if test "$latexdiff_flatten" = 1; then
    latexdiffopt+=("--flatten")
fi

# Shortcut to include bbl
if test "$bbl" = 1; then
    bblexpand=("--expand-bbl" "$mainbase.bbl")
else
    bblexpand=()
fi

# Create flattened documents and keep for debugging
if test "$flatten" = 1; then
    if [ "$bbl" = 1 ]; then
	if [ ! -f "old/$maindir$mainbase.bbl" ]; then
	    verbose "Attempting to regenerate missing old/$maindir$mainbase.bbl"
	    (
		cd old/"$maindir"
		log_cmd pdflatex0.log pdflatex $latexopt "$mainbase" || compile_error=1
		log_cmd bibtex0.log bibtex "$mainbase" || compile_error=1
	    )
	    if [ "$compile_error" = 1 ]; then
		die "Failed to regenerate .bbl for old version"
	    fi
	fi
	if [ ! -f "new/$maindir$mainbase.bbl" ]; then
	    verbose "Attempting to regenerate missing new/$maindir$mainbase.bbl"
	    (
		cd new/"$maindir"
		log_cmd pdflatex0.log pdflatex $latexopt "$mainbase" || compile_error=1
		log_cmd bibtex0.log bibtex "$mainbase" || compile_error=1
	    )
	    if [ "$compile_error" = 1 ]; then
		die "Failed to regenerate .bbl for new version"
	    fi
	fi
    fi
    verbose "Running latexpand"
    (
	cd old/"$maindir" &&
	latexpand "$mainbase".tex "${latexpand[@]}" "${bblexpand[@]}"
    ) > old-"$mainbase"-fl.tex \
	|| die "latexpand failed for old version"
    (
	cd new/"$maindir" &&
	latexpand "$mainbase".tex "${latexpand[@]}" "${bblexpand[@]}"
    ) > new-"$mainbase"-fl.tex \
	|| die "latexpand failed for new version"
    verbose_done

    verbose "Running latexdiff ${latexdiffopt[@]} old-${mainbase}-fl.tex new-${mainbase}-fl.tex > ./diff.tex"
    latexdiff "${latexdiffopt[@]}" old-"$mainbase"-fl.tex new-"$mainbase"-fl.tex > diff.tex \
	|| die "latexdiff failed"
    verbose_done

    verbose "mv ./diff.tex new/$main"
    mv -f new-"$mainbase"-fl.tex new-"$mainbase"-fl.tex.orig
    mv -f diff.tex new/"$main"
    verbose_done
else
    verbose "Running latexdiff ${latexdiffopt[@]} old/$main new/$main > ./diff.tex"
    latexdiff "${latexdiffopt[@]}" old/"$main" new/"$main" > diff.tex \
	|| die "latexdiff failed"
    verbose_done

    verbose "mv ./diff.tex new/$main"
    mv -f new/"$main" new/"$main.orig"
    mv -f diff.tex new/"$main"
    verbose_done
fi

verbose "Compiling result"

compile_error=0
cd new/"$maindir" || die "Can't cd to new/$maindir"
if test -f Makefile && test "$ignoremake" != 1 ; then
    log_cmd make.log make || compile_error=1
elif test "$uselatexmk" = 1; then
    log_cmd latexmk.log latexmk -f -pdf -silent "$mainbase" || compile_error=1
else
    if [ "$ignorelatexerrors" = 1 ]; then
	latexopt="$latexopt -interaction=batchmode"
    elif [ "$quiet" = 1 ]; then
	latexopt="$latexopt -interaction=nonstopmode"
    else
	latexopt="$latexopt -interaction=errorstopmode"
    fi
    log_cmd pdflatex1.log pdflatex $latexopt "$mainbase" || compile_error=1
    if test "$bibtex" = 1 ; then
	log_cmd bibtex.log bibtex "$mainbase" || compile_error=1
    fi
    if test "$biber" = 1 ; then
	log_cmd biber.log biber "$mainbase" || compile_error=1
    fi
    log_cmd pdflatex2.log pdflatex $latexopt "$mainbase" || compile_error=1
    log_cmd pdflatex3.log pdflatex $latexopt "$mainbase" || compile_error=1
fi

verbose_done

if [ "$compile_error" = 1 ] && [ "$ignorelatexerrors" = 1 ]; then
    echo "LaTeX errors were found - but attempting to carry on."
    compile_error=0
fi

pdffile="$mainbase".pdf
if test ! -r "$pdffile" ; then
    echo "No PDF file generated."
    compile_error=1
fi

if test ! -s "$pdffile" ; then
    echo "PDF file generated is empty."
    compile_error=1
fi

if test "$compile_error" = "1" ; then
    echo "Error during compilation. Please examine and cleanup if needed:"
    echo "Directory: $tmpdir/new/$maindir"
    echo "     File: $mainbase.tex"
    # Don't clean up to let the user diagnose.
    exit 1
fi

if test -n "$output" ; then
    abs_pdffile="$PWD/$pdffile"
    (cd "$initial_dir" && mv "$abs_pdffile" "$output")
    echo "Output written on $output"
elif [ -f "$pdffile" ]; then
    new_pdffile="$tmpdir"/"$pdffile"
    mv "$pdffile" "$new_pdffile"
    pdffile="$new_pdffile"
fi


if test "$view" = 1  || test "$view" = maybe  && test -z "$output" ; then
    "$PDFVIEWER" "$pdffile"
fi

case "$cleanup" in
    "all")
	verbose "Cleaning-up result"
	cd ..
	cd ..
	rm -fr "$tmpdir"
	verbose_done
	;;
    "keeppdf")
	verbose "Cleaning-up all but pdf (kept in $pdffile)"
	rm -fr "$tmpdir"/old "$tmpdir"/new
	verbose_done
	;;
    "none")
	verbose_say "Generated files kept in $tmpdir/"
	;;
esac
