C'est très probablement le safeguard d'indexation des worklogs de Jira Data Center, et non un bug de Jira Assistant ou d'App Time. Par défaut, Jira n'indexe que 100 worklogs maximum par ticket, une limite modifiable via la propriété système jira.safeguards.indexing.issue.worklogs. Au-delà, les requêtes JQL utilisant worklogAuthor ou worklogDate ne portent que sur les 100 saisies les plus récentes.  

Les deux plugins interrogent l'index. Sur votre ticket de vacances, qui compte des milliers de saisies, les 100 « plus récentes » sont celles dont la date est la plus lointaine dans le futur. Les saisies à plus de 6 semaines apparaissent donc, et toutes les autres disparaissent. Cela correspond exactement à votre symptôme.

Pourquoi le problème apparaît maintenant : la montée de version a déclenché une réindexation complète. Si ce paramètre avait été augmenté sous Jira 10, il a probablement été perdu, parce que setenv.sh (ou les options Java du service Windows) est remplacé par la nouvelle installation.

Correctif :

	1.	Vérifier. Dans Administration › Système › Informations système, regardez les arguments JVM, et comparez avec le setenv.sh de l'ancienne installation. Dans atlassian-jira.log, les stats [INDEXING-LIMITS] contiennent topIssuesWithLimitedWorklogs, la liste des tickets ayant le plus de worklogs hors limite d'indexation. Votre ticket de vacances devrait y figurer. 
	2.	Ajouter le paramètre dans JVM_SUPPORT_RECOMMENDED_ARGS. La valeur -1 supprime la limite, ou bien vous pouvez mettre une valeur élevée, par exemple 10000 worklogs par ticket.  
	3.	Redémarrer. Le paramètre doit être appliqué sur chaque nœud, puis tous les nœuds redémarrés. 
	4.	Réindexer, au minimum le projet qui contient le ticket. Sans réindexation, les worklogs déjà tronqués restent absents des recherches et des rapports. 

À noter : augmenter cette limite peut affecter les performances de la recherche. À plus long terme, découper le ticket de vacances par année réduirait le problème. 

Sources :

	•	Jira indexing-limits stats
	•	JQL worklogAuthor missing issues (Atlassian KB)
	•	Jira Data Center not returning All Worklogs
