# Copyright 1998-2007 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Id$

from portage.cache.cache_errors import CacheError
from portage.const import REPO_NAME_LOC
from portage.data import portage_gid, secpass
from portage.dbapi import dbapi
from portage.dep import use_reduce, paren_reduce, dep_getslot, dep_getkey, \
	match_from_list, match_to_list
from portage.exception import OperationNotPermitted, PortageException, \
	UntrustedSignature, SecurityViolation, InvalidSignature, MissingSignature, \
	FileNotFound, InvalidDependString
from portage.manifest import Manifest
from portage.output import red
from portage.util import ensure_dirs, writemsg, apply_recursive_permissions
from portage.versions import pkgsplit, catpkgsplit, best

import portage.gpg, portage.checksum

from portage import eclass_cache, auxdbkeys, auxdbkeylen, doebuild, flatten, \
	listdir, dep_expand, eapi_is_supported, key_expand, dep_check

import os, stat, sys


class portdbapi(dbapi):
	"""this tree will scan a portage directory located at root (passed to init)"""
	portdbapi_instances = []

	def __init__(self, porttree_root, mysettings=None):
		portdbapi.portdbapi_instances.append(self)

		from portage import config
		if mysettings:
			self.mysettings = mysettings
		else:
			from portage import settings
			self.mysettings = config(clone=settings)
		self._categories = set(self.mysettings.categories)
		# This is strictly for use in aux_get() doebuild calls when metadata
		# is generated by the depend phase.  It's safest to use a clone for
		# this purpose because doebuild makes many changes to the config
		# instance that is passed in.
		self.doebuild_settings = config(clone=self.mysettings)

		self.manifestVerifyLevel = None
		self.manifestVerifier = None
		self.manifestCache = {}    # {location: [stat, md5]}
		self.manifestMissingCache = []

		if "gpg" in self.mysettings.features:
			self.manifestVerifyLevel = portage.gpg.EXISTS
			if "strict" in self.mysettings.features:
				self.manifestVerifyLevel = portage.gpg.MARGINAL
				self.manifestVerifier = portage.gpg.FileChecker(self.mysettings["PORTAGE_GPG_DIR"], "gentoo.gpg", minimumTrust=self.manifestVerifyLevel)
			elif "severe" in self.mysettings.features:
				self.manifestVerifyLevel = portage.gpg.TRUSTED
				self.manifestVerifier = portage.gpg.FileChecker(self.mysettings["PORTAGE_GPG_DIR"], "gentoo.gpg", requireSignedRing=True, minimumTrust=self.manifestVerifyLevel)
			else:
				self.manifestVerifier = portage.gpg.FileChecker(self.mysettings["PORTAGE_GPG_DIR"], "gentoo.gpg", minimumTrust=self.manifestVerifyLevel)

		#self.root=settings["PORTDIR"]
		self.porttree_root = os.path.realpath(porttree_root)

		self.depcachedir = self.mysettings.depcachedir[:]

		self.tmpfs = self.mysettings["PORTAGE_TMPFS"]
		if self.tmpfs and not os.path.exists(self.tmpfs):
			self.tmpfs = None
		if self.tmpfs and not os.access(self.tmpfs, os.W_OK):
			self.tmpfs = None
		if self.tmpfs and not os.access(self.tmpfs, os.R_OK):
			self.tmpfs = None

		self.eclassdb = eclass_cache.cache(self.porttree_root,
			overlays=self.mysettings["PORTDIR_OVERLAY"].split())

		self.metadbmodule = self.mysettings.load_best_module("portdbapi.metadbmodule")

		#if the portdbapi is "frozen", then we assume that we can cache everything (that no updates to it are happening)
		self.xcache = {}
		self.frozen = 0

		self.porttrees = [self.porttree_root] + \
			[os.path.realpath(t) for t in self.mysettings["PORTDIR_OVERLAY"].split()]
		self.treemap = {}
		for path in self.porttrees:
			repo_name_path = os.path.join(path, REPO_NAME_LOC)
			try:
				repo_name = open(repo_name_path, 'r').readline().strip()
				self.treemap[repo_name] = path
			except (OSError,IOError):
				# warn about missing repo_name at some other time, since we
				# don't want to see a warning every time the portage module is
				# imported.
				pass
		
		self.auxdbmodule = self.mysettings.load_best_module("portdbapi.auxdbmodule")
		self.auxdb = {}
		self._init_cache_dirs()
		# XXX: REMOVE THIS ONCE UNUSED_0 IS YANKED FROM auxdbkeys
		# ~harring
		filtered_auxdbkeys = filter(lambda x: not x.startswith("UNUSED_0"), auxdbkeys)
		if secpass < 1:
			from portage.cache import metadata_overlay, volatile
			for x in self.porttrees:
				db_ro = self.auxdbmodule(self.depcachedir, x,
					filtered_auxdbkeys, gid=portage_gid, readonly=True)
				self.auxdb[x] = metadata_overlay.database(
					self.depcachedir, x, filtered_auxdbkeys,
					gid=portage_gid, db_rw=volatile.database,
					db_ro=db_ro)
		else:
			for x in self.porttrees:
				# location, label, auxdbkeys
				self.auxdb[x] = self.auxdbmodule(
					self.depcachedir, x, filtered_auxdbkeys, gid=portage_gid)
		# Selectively cache metadata in order to optimize dep matching.
		self._aux_cache_keys = set(["EAPI", "KEYWORDS", "LICENSE", "SLOT"])
		self._aux_cache = {}
		self._broken_ebuilds = set()

	def _init_cache_dirs(self):
		"""Create /var/cache/edb/dep and adjust permissions for the portage
		group."""

		dirmode = 02070
		filemode =   060
		modemask =    02

		try:
			ensure_dirs(self.depcachedir, gid=portage_gid,
				mode=dirmode, mask=modemask)
		except PortageException, e:
			pass

	def close_caches(self):
		if not hasattr(self, "auxdb"):
			# unhandled exception thrown from constructor
			return
		for x in self.auxdb:
			self.auxdb[x].sync()
		self.auxdb.clear()

	def flush_cache(self):
		for x in self.auxdb.values():
			x.sync()

	def finddigest(self,mycpv):
		try:
			mydig = self.findname2(mycpv)[0]
			if not mydig:
				return ""
			mydigs = mydig.split("/")[:-1]
			mydig = "/".join(mydigs)
			mysplit = mycpv.split("/")
		except OSError:
			return ""
		return mydig+"/files/digest-"+mysplit[-1]

	def findLicensePath(self, license_name):
		mytrees = self.porttrees[:]
		mytrees.reverse()
		for x in mytrees:
			license_path = os.path.join(x, "licenses", license_name)
			if os.access(license_path, os.R_OK):
				return license_path
		return None

	def findname(self,mycpv):
		return self.findname2(mycpv)[0]

	def getRepositoryPath(self, repository_id):
		"""
		This function is required for GLEP 42 compliance; given a valid repository ID
		it must return a path to the repository
		TreeMap = { id:path }
		"""
		if repository_id in self.treemap:
			return self.treemap[repository_id]
		return None

	def getRepositories(self):
		"""
		This function is required for GLEP 42 compliance; it will return a list of
		repository ID's
		TreeMap = {id: path}
		"""
		return [k for k in self.treemap if k]

	def findname2(self, mycpv, mytree=None):
		""" 
		Returns the location of the CPV, and what overlay it was in.
		Searches overlays first, then PORTDIR; this allows us to return the first
		matching file.  As opposed to starting in portdir and then doing overlays
		second, we would have to exhaustively search the overlays until we found
		the file we wanted.
		"""
		if not mycpv:
			return "",0
		mysplit = mycpv.split("/")
		psplit = pkgsplit(mysplit[1])

		if mytree:
			mytrees = [mytree]
		else:
			mytrees = self.porttrees[:]
			mytrees.reverse()
		if psplit:
			for x in mytrees:
				file=x+"/"+mysplit[0]+"/"+psplit[0]+"/"+mysplit[1]+".ebuild"
				if os.access(file, os.R_OK):
					return[file, x]
		return None, 0

	def aux_get(self, mycpv, mylist, mytree=None):
		"stub code for returning auxilliary db information, such as SLOT, DEPEND, etc."
		'input: "sys-apps/foo-1.0",["SLOT","DEPEND","HOMEPAGE"]'
		'return: ["0",">=sys-libs/bar-1.0","http://www.foo.com"] or raise KeyError if error'
		cache_me = False
		if not mytree and not set(mylist).difference(self._aux_cache_keys):
			aux_cache = self._aux_cache.get(mycpv)
			if aux_cache is not None:
				return [aux_cache[x] for x in mylist]
			cache_me = True
		global auxdbkeys, auxdbkeylen
		cat,pkg = mycpv.split("/", 1)

		myebuild, mylocation = self.findname2(mycpv, mytree)

		if not myebuild:
			writemsg("!!! aux_get(): ebuild path for '%(cpv)s' not specified:\n" % {"cpv":mycpv},
				noiselevel=1)
			writemsg("!!!            %s\n" % myebuild, noiselevel=1)
			raise KeyError(mycpv)

		myManifestPath = "/".join(myebuild.split("/")[:-1])+"/Manifest"
		if "gpg" in self.mysettings.features:
			try:
				mys = portage.gpg.fileStats(myManifestPath)
				if (myManifestPath in self.manifestCache) and \
				   (self.manifestCache[myManifestPath] == mys):
					pass
				elif self.manifestVerifier:
					if not self.manifestVerifier.verify(myManifestPath):
						# Verification failed the desired level.
						raise UntrustedSignature, "Untrusted Manifest: %(manifest)s" % {"manifest":myManifestPath}

				if ("severe" in self.mysettings.features) and \
				   (mys != portage.gpg.fileStats(myManifestPath)):
					raise SecurityViolation, "Manifest changed: %(manifest)s" % {"manifest":myManifestPath}

			except InvalidSignature, e:
				if ("strict" in self.mysettings.features) or \
				   ("severe" in self.mysettings.features):
					raise
				writemsg("!!! INVALID MANIFEST SIGNATURE DETECTED: %(manifest)s\n" % {"manifest":myManifestPath})
			except MissingSignature, e:
				if ("severe" in self.mysettings.features):
					raise
				if ("strict" in self.mysettings.features):
					if myManifestPath not in self.manifestMissingCache:
						writemsg("!!! WARNING: Missing signature in: %(manifest)s\n" % {"manifest":myManifestPath})
						self.manifestMissingCache.insert(0,myManifestPath)
			except (OSError, FileNotFound), e:
				if ("strict" in self.mysettings.features) or \
				   ("severe" in self.mysettings.features):
					raise SecurityViolation, "Error in verification of signatures: %(errormsg)s" % {"errormsg":str(e)}
				writemsg("!!! Manifest is missing or inaccessable: %(manifest)s\n" % {"manifest":myManifestPath},
					noiselevel=-1)


		if os.access(myebuild, os.R_OK):
			emtime = os.stat(myebuild)[stat.ST_MTIME]
		else:
			writemsg("!!! aux_get(): ebuild for '%(cpv)s' does not exist at:\n" % {"cpv":mycpv},
				noiselevel=-1)
			writemsg("!!!            %s\n" % myebuild,
				noiselevel=-1)
			raise KeyError

		try:
			mydata = self.auxdb[mylocation][mycpv]
			if emtime != long(mydata.get("_mtime_", 0)):
				doregen = True
			elif len(mydata.get("_eclasses_", [])) > 0:
				doregen = not self.eclassdb.is_eclass_data_valid(mydata["_eclasses_"])
			else:
				doregen = False
				
		except KeyError:
			doregen = True
		except CacheError:
			doregen = True
			try:
				del self.auxdb[mylocation][mycpv]
			except KeyError:
				pass

		writemsg("auxdb is valid: "+str(not doregen)+" "+str(pkg)+"\n", 2)

		if doregen:
			if myebuild in self._broken_ebuilds:
				raise KeyError(mycpv)
			writemsg("doregen: %s %s\n" % (doregen, mycpv), 2)
			writemsg("Generating cache entry(0) for: "+str(myebuild)+"\n", 1)

			self.doebuild_settings.reset()
			mydata = {}
			myret = doebuild(myebuild, "depend",
				self.doebuild_settings["ROOT"], self.doebuild_settings,
				dbkey=mydata, tree="porttree", mydbapi=self)
			if myret != os.EX_OK:
				self._broken_ebuilds.add(myebuild)
				raise KeyError(mycpv)

			if "EAPI" not in mydata or not mydata["EAPI"].strip():
				mydata["EAPI"] = "0"

			if not eapi_is_supported(mydata["EAPI"]):
				# if newer version, wipe everything and negate eapi
				eapi = mydata["EAPI"]
				mydata = {}
				map(lambda x: mydata.setdefault(x, ""), auxdbkeys)
				mydata["EAPI"] = "-"+eapi

			if mydata.get("INHERITED", False):
				mydata["_eclasses_"] = self.eclassdb.get_eclass_data(mydata["INHERITED"].split())
			else:
				mydata["_eclasses_"] = {}
			
			del mydata["INHERITED"]

			mydata["_mtime_"] = emtime

			self.auxdb[mylocation][mycpv] = mydata

		if not mydata.setdefault("EAPI", "0"):
			mydata["EAPI"] = "0"

		#finally, we look at our internal cache entry and return the requested data.
		returnme = []
		for x in mylist:
			if x == "INHERITED":
				returnme.append(' '.join(mydata.get("_eclasses_", [])))
			else:
				returnme.append(mydata.get(x,""))

		if cache_me:
			aux_cache = {}
			for x in self._aux_cache_keys:
				aux_cache[x] = mydata.get(x, "")
			self._aux_cache[mycpv] = aux_cache

		return returnme

	def getfetchlist(self, mypkg, useflags=None, mysettings=None, all=0, mytree=None):
		if mysettings is None:
			mysettings = self.mysettings
		try:
			myuris = self.aux_get(mypkg, ["SRC_URI"], mytree=mytree)[0]
		except KeyError:
			# Convert this to an InvalidDependString exception since callers
			# already handle it.
			raise portage.exception.InvalidDependString(
				"getfetchlist(): aux_get() error reading "+mypkg+"; aborting.")

		if useflags is None:
			useflags = mysettings["USE"].split()

		myurilist = paren_reduce(myuris)
		myurilist = use_reduce(myurilist, uselist=useflags, matchall=all)
		newuris = flatten(myurilist)

		myfiles = []
		for x in newuris:
			mya = os.path.basename(x)
			if not mya:
				raise portage.exception.InvalidDependString("URI has no basename: '%s'" % x)
			if not mya in myfiles:
				myfiles.append(mya)
		return [newuris, myfiles]

	def getfetchsizes(self, mypkg, useflags=None, debug=0):
		# returns a filename:size dictionnary of remaining downloads
		myebuild = self.findname(mypkg)
		pkgdir = os.path.dirname(myebuild)
		mf = Manifest(pkgdir, self.mysettings["DISTDIR"])
		checksums = mf.getDigests()
		if not checksums:
			if debug: 
				print "[empty/missing/bad digest]: "+mypkg
			return None
		filesdict={}
		if useflags is None:
			myuris, myfiles = self.getfetchlist(mypkg,all=1)
		else:
			myuris, myfiles = self.getfetchlist(mypkg,useflags=useflags)
		#XXX: maybe this should be improved: take partial downloads
		# into account? check checksums?
		for myfile in myfiles:
			if myfile not in checksums:
				if debug:
					writemsg("[bad digest]: missing %s for %s\n" % (myfile, mypkg))
				continue
			file_path = os.path.join(self.mysettings["DISTDIR"], myfile)
			mystat = None
			try:
				mystat = os.stat(file_path)
			except OSError, e:
				pass
			if mystat is None:
				existing_size = 0
			else:
				existing_size = mystat.st_size
			remaining_size = int(checksums[myfile]["size"]) - existing_size
			if remaining_size > 0:
				# Assume the download is resumable.
				filesdict[myfile] = remaining_size
			elif remaining_size < 0:
				# The existing file is too large and therefore corrupt.
				filesdict[myfile] = int(checksums[myfile]["size"])
		return filesdict

	def fetch_check(self, mypkg, useflags=None, mysettings=None, all=False):
		if not useflags:
			if mysettings:
				useflags = mysettings["USE"].split()
		myuri, myfiles = self.getfetchlist(mypkg, useflags=useflags, mysettings=mysettings, all=all)
		myebuild = self.findname(mypkg)
		pkgdir = os.path.dirname(myebuild)
		mf = Manifest(pkgdir, self.mysettings["DISTDIR"])
		mysums = mf.getDigests()

		failures = {}
		for x in myfiles:
			if not mysums or x not in mysums:
				ok     = False
				reason = "digest missing"
			else:
				try:
					ok, reason = portage.checksum.verify_all(
						os.path.join(self.mysettings["DISTDIR"], x), mysums[x])
				except FileNotFound, e:
					ok = False
					reason = "File Not Found: '%s'" % str(e)
			if not ok:
				failures[x] = reason
		if failures:
			return False
		return True

	def cpv_exists(self, mykey):
		"Tells us whether an actual ebuild exists on disk (no masking)"
		cps2 = mykey.split("/")
		cps = catpkgsplit(mykey, silent=0)
		if not cps:
			#invalid cat/pkg-v
			return 0
		if self.findname(cps[0] + "/" + cps2[1]):
			return 1
		else:
			return 0

	def cp_all(self):
		"returns a list of all keys in our tree"
		d = {}
		for x in self.mysettings.categories:
			for oroot in self.porttrees:
				for y in listdir(oroot+"/"+x, EmptyOnError=1, ignorecvs=1, dirsonly=1):
					d[x+"/"+y] = None
		l = d.keys()
		l.sort()
		return l

	def p_list(self,mycp):
		d={}
		for oroot in self.porttrees:
			for x in listdir(oroot+"/"+mycp,EmptyOnError=1,ignorecvs=1):
				if x[-7:]==".ebuild":
					d[x[:-7]] = None
		return d.keys()

	def cp_list(self, mycp, use_cache=1, mytree=None):
		mysplit = mycp.split("/")
		invalid_category = mysplit[0] not in self._categories
		d={}
		if mytree:
			mytrees = [mytree]
		else:
			mytrees = self.porttrees
		for oroot in mytrees:
			for x in listdir(oroot+"/"+mycp, EmptyOnError=1, ignorecvs=1):
				if x.endswith(".ebuild"):
					pf = x[:-7]
					ps = pkgsplit(pf)
					if not ps:
						writemsg("\nInvalid ebuild name: %s\n" % \
							os.path.join(oroot, mycp, x), noiselevel=-1)
						continue
					d[mysplit[0]+"/"+pf] = None
		if invalid_category and d:
			writemsg(("\n!!! '%s' has a category that is not listed in " + \
				"/etc/portage/categories\n") % mycp, noiselevel=-1)
			return []
		return d.keys()

	def freeze(self):
		for x in ["list-visible", "bestmatch-visible", "match-visible", "match-all"]:
			self.xcache[x]={}
		self.frozen=1

	def melt(self):
		self.xcache = {}
		self.frozen = 0

	def xmatch(self,level,origdep,mydep=None,mykey=None,mylist=None):
		"caching match function; very trick stuff"
		#if no updates are being made to the tree, we can consult our xcache...
		if self.frozen:
			try:
				return self.xcache[level][origdep][:]
			except KeyError:
				pass

		if not mydep:
			#this stuff only runs on first call of xmatch()
			#create mydep, mykey from origdep
			mydep = dep_expand(origdep, mydb=self, settings=self.mysettings)
			mykey = dep_getkey(mydep)

		if level == "list-visible":
			#a list of all visible packages, not called directly (just by xmatch())
			#myval = self.visible(self.cp_list(mykey))

			myval = self.gvisible(self.visible(self.cp_list(mykey)))
		elif level == "bestmatch-visible":
			#dep match -- best match of all visible packages
			#get all visible matches (from xmatch()), then choose the best one

			myval = best(self.xmatch("match-visible", None, mydep=mydep, mykey=mykey))
		elif level == "bestmatch-list":
			#dep match -- find best match but restrict search to sublist
			#no point in calling xmatch again since we're not caching list deps

			myval = best(match_from_list(mydep, mylist))
		elif level == "match-list":
			#dep match -- find all matches but restrict search to sublist (used in 2nd half of visible())

			myval = match_from_list(mydep, mylist)
		elif level == "match-visible":
			#dep match -- find all visible matches
			#get all visible packages, then get the matching ones

			myval = match_from_list(mydep,
				self.xmatch("list-visible", mykey, mydep=mykey, mykey=mykey))
		elif level == "match-all":
			#match *all* visible *and* masked packages
			
			myval = match_from_list(mydep, self.cp_list(mykey))
		else:
			print "ERROR: xmatch doesn't handle", level, "query!"
			raise KeyError
		myslot = dep_getslot(mydep)
		if myslot is not None:
			slotmatches = []
			for cpv in myval:
				try:
					if self.aux_get(cpv, ["SLOT"])[0] == myslot:
						slotmatches.append(cpv)
				except KeyError:
					pass # ebuild masked by corruption
			myval = slotmatches
		if self.frozen and (level not in ["match-list", "bestmatch-list"]):
			self.xcache[level][mydep] = myval
			if origdep and origdep != mydep:
				self.xcache[level][origdep] = myval
		return myval[:]

	def match(self, mydep, use_cache=1):
		return self.xmatch("match-visible", mydep)

	def visible(self, mylist):
		"""two functions in one.  Accepts a list of cpv values and uses the package.mask *and*
		packages file to remove invisible entries, returning remaining items.  This function assumes
		that all entries in mylist have the same category and package name."""
		if (mylist is None) or (len(mylist) == 0):
			return []
		newlist = mylist[:]
		#first, we mask out packages in the package.mask file
		mykey = newlist[0]
		cpv = catpkgsplit(mykey)
		if not cpv:
			#invalid cat/pkg-v
			print "visible(): invalid cat/pkg-v:", mykey
			return []
		mycp = cpv[0] + "/" + cpv[1]
		maskdict = self.mysettings.pmaskdict
		unmaskdict = self.mysettings.punmaskdict
		if maskdict.has_key(mycp):
			for x in maskdict[mycp]:
				mymatches = self.xmatch("match-all", x)
				if mymatches is None:
					#error in package.mask file; print warning and continue:
					print "visible(): package.mask entry \"" + x + "\" is invalid, ignoring..."
					continue
				for y in mymatches:
					unmask = 0
					if unmaskdict.has_key(mycp):
						for z in unmaskdict[mycp]:
							mymatches_unmask = self.xmatch("match-all",z)
							if y in mymatches_unmask:
								unmask = 1
								break
					if unmask == 0:
						try:
							newlist.remove(y)
						except ValueError:
							pass

		profile_atoms = self.mysettings.prevmaskdict.get(mycp)
		if profile_atoms:
			for x in profile_atoms:
				#important: only match against the still-unmasked entries...
				#notice how we pass "newlist" to the xmatch() call below....
				#Without this, ~ deps in the packages files are broken.
				mymatches=self.xmatch("match-list",x,mylist=newlist)
				if mymatches is None:
					#error in packages file; print warning and continue:
					print "emerge: visible(): profile packages entry \""+x+"\" is invalid, ignoring..."
					continue
				newlist = [cpv for cpv in newlist if cpv in mymatches]

		return newlist

	def gvisible(self,mylist):
		"strip out group-masked (not in current group) entries"

		if mylist is None:
			return []
		newlist=[]

		accept_keywords = self.mysettings["ACCEPT_KEYWORDS"].split()
		pkgdict = self.mysettings.pkeywordsdict
		aux_keys = ["KEYWORDS", "LICENSE", "EAPI", "SLOT"]

		# Hack: Need to check the env directly here as otherwise stacking 
		# doesn't work properly as negative values are lost in the config
		# object (bug #139600)
		egroups = self.mysettings.configdict["backupenv"].get(
			"ACCEPT_KEYWORDS", "").split()

		for mycpv in mylist:
			try:
				keys, licenses, eapi, slot = self.aux_get(mycpv, aux_keys)
			except KeyError:
				continue
			except PortageException, e:
				writemsg("!!! Error: aux_get('%s', %s)\n" % (mycpv, aux_keys),
					mycpv, noiselevel=-1)
				writemsg("!!! %s\n" % str(e), noiselevel=-1)
				del e
				continue
			mygroups = keys.split()
			# Repoman may modify this attribute as necessary.
			pgroups = accept_keywords[:]
			match=0
			cp = dep_getkey(mycpv)
			if pkgdict.has_key(cp):
				cpv_slot = "%s:%s" % (mycpv, slot)
				matches = match_to_list(cpv_slot, pkgdict[cp].keys())
				for atom in matches:
					pgroups.extend(pkgdict[cp][atom])
				pgroups.extend(egroups)
				if matches:
					# normalize pgroups with incrementals logic so it 
					# matches ACCEPT_KEYWORDS behavior
					inc_pgroups = []
					for x in pgroups:
						if x == "-*":
							inc_pgroups = []
						elif x[0] == "-":
							try:
								inc_pgroups.remove(x[1:])
							except ValueError:
								pass
						elif x not in inc_pgroups:
							inc_pgroups.append(x)
					pgroups = inc_pgroups
					del inc_pgroups
			hasstable = False
			hastesting = False
			for gp in mygroups:
				if gp == "*" or (gp == "-*" and len(mygroups) == 1):
					writemsg("--- WARNING: Package '%s' uses '%s' keyword.\n" % (mycpv, gp),
						noiselevel=-1)
					if gp == "*":
						match = 1
						break
				elif gp in pgroups:
					match=1
					break
				elif gp[0] == "~":
					hastesting = True
				elif gp[0] != "-":
					hasstable = True
			if not match and ((hastesting and "~*" in pgroups) or (hasstable and "*" in pgroups) or "**" in pgroups):
				match=1
			uselist = []
			if "?" in licenses:
				self.doebuild_settings.setcpv(mycpv, mydb=self)
				uselist = self.doebuild_settings.get("USE", "").split()
			try:
				if self.mysettings.getMissingLicenses(
					licenses, mycpv, uselist):
					match = 0
			except InvalidDependString:
				match = 0
			if match and eapi_is_supported(eapi):
				newlist.append(mycpv)
		return newlist


def close_portdbapi_caches():
	for i in portdbapi.portdbapi_instances:
		i.close_caches()


class portagetree(object):
	def __init__(self, root="/", virtual=None, clone=None, settings=None):
		"""
		Constructor for a PortageTree
		
		@param root: ${ROOT}, defaults to '/', see make.conf(5)
		@type root: String/Path
		@param virtual: UNUSED
		@type virtual: No Idea
		@param clone: Set this if you want a copy of Clone
		@type clone: Existing portagetree Instance
		@param settings: Portage Configuration object (portage.settings)
		@type settings: Instance of portage.config
		"""

		if clone:
			writemsg("portagetree.__init__(): deprecated " + \
				"use of clone parameter\n", noiselevel=-1)
			self.root = clone.root
			self.portroot = clone.portroot
			self.pkglines = clone.pkglines
		else:
			self.root = root
			if settings is None:
				from portage import settings
			self.settings = settings
			self.portroot = settings["PORTDIR"]
			self.virtual = virtual
			self.dbapi = portdbapi(
				settings["PORTDIR"], mysettings=settings)

	def dep_bestmatch(self,mydep):
		"compatibility method"
		mymatch = self.dbapi.xmatch("bestmatch-visible",mydep)
		if mymatch is None:
			return ""
		return mymatch

	def dep_match(self,mydep):
		"compatibility method"
		mymatch = self.dbapi.xmatch("match-visible",mydep)
		if mymatch is None:
			return []
		return mymatch

	def exists_specific(self,cpv):
		return self.dbapi.cpv_exists(cpv)

	def getallnodes(self):
		"""new behavior: these are all *unmasked* nodes.  There may or may not be available
		masked package for nodes in this nodes list."""
		return self.dbapi.cp_all()

	def getname(self, pkgname):
		"returns file location for this particular package (DEPRECATED)"
		if not pkgname:
			return ""
		mysplit = pkgname.split("/")
		psplit = pkgsplit(mysplit[1])
		return "/".join([self.portroot, mysplit[0], psplit[0], mysplit[1]])+".ebuild"

	def resolve_specific(self, myspec):
		cps = catpkgsplit(myspec)
		if not cps:
			return None
		mykey = key_expand(cps[0]+"/"+cps[1], mydb=self.dbapi,
			settings=self.settings)
		mykey = mykey + "-" + cps[2]
		if cps[3] != "r0":
			mykey = mykey + "-" + cps[3]
		return mykey

	def depcheck(self, mycheck, use="yes", myusesplit=None):
		return dep_check(mycheck, self.dbapi, use=use, myuse=myusesplit)

	def getslot(self,mycatpkg):
		"Get a slot for a catpkg; assume it exists."
		myslot = ""
		try:
			myslot = self.dbapi.aux_get(mycatpkg, ["SLOT"])[0]
		except SystemExit, e:
			raise
		except Exception, e:
			pass
		return myslot

